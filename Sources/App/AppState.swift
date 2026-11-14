import AppKit
import AVFoundation
import Foundation
import Observation
import OSLog

typealias ErrorResetSleeper = @Sendable (UInt64) async throws -> Void
typealias FeedbackFlashSleeper = @Sendable (UInt64) async throws -> Void
typealias RecordingDurationSleeper = @Sendable (UInt64) async throws -> Void
typealias AutoPasteSleeper = @Sendable (UInt64) async throws -> Void

/// Owns the pipeline state and orchestrates each run: which events start or stop it
/// (`PipelineTransitions`), recording and transcription, transformation, and committing the result.
/// How committed text reaches the editor lives in `DeliveryCoordinator`.
@MainActor
@Observable
final class AppState {
    typealias PipelineState = Syrup.PipelineState

    private static let minimumHold: Duration = .milliseconds(300)
    private static let outputVolumeLogger = Logger(subsystem: "org.syrup.SyrupApp", category: "OutputVolume")

    /// A finished result whose clipboard write failed, kept so Copy Result can deliver it later.
    /// `output` is the exact result that history keeps; `delivered` is the sentence-fitted text.
    private struct PendingClipboardResult {
        let output: String
        let delivered: String
        let transcript: String
        let transformation: DictationRecord.TransformationSnapshot
        let provider: TranslationProvider
    }

    /// A finished transformation on its way out. History keeps `output`, so Copy Last and revisions
    /// see the exact result; the clipboard and editor receive `fitted.text`.
    private struct CompletedOutput {
        let output: String
        let fitted: FittedText
        let transcript: String
        let configuration: RunConfiguration
    }

    private var pendingPasteID: UUID?
    private var pendingClipboardResult: PendingClipboardResult?

    private(set) var pipelineState: PipelineState = .idle {
        willSet {
            if newValue != .recording { isFnRecordingLatched = false }
        }
        didSet {
            hotkeyController?.setCancelShortcutEnabled(pipelineState.allowsCancelShortcut)
            syncRecordingCue()
        }
    }
    /// Set while the onboarding's try-it page is open, so its first result lands there and not in Syrup's own window.
    var holdsPasteForOnboarding = false

    /// A hold-mode recording that a Fn double-tap keeps open after release, so releasing a key will not finish it.
    var isFnRecordingLatched = false

    var isHotkeyPaused = false {
        didSet {
            if isHotkeyPaused {
                cancelRequested()
            }
            hotkeyController?.setListening(isHotkeyPaused == false)
        }
    }
    let settings: AppSettings
    let transcriberAssetManager: TranscriberAssetManager
    let history: HistoryStore
    let autoPaster: any AutoPasting
    @ObservationIgnored let keychainStore: KeychainStore
    private var isShowingSuccessFeedback = false {
        didSet {
            syncRecordingCue()
        }
    }

    @ObservationIgnored private let audioRecorder: any AudioRecording
    @ObservationIgnored private let transcriber: any Transcriber
    @ObservationIgnored private let speechModels: [SpeechEngine: InstalledSpeechModel]
    let usageStats: UsageStatsStore
    @ObservationIgnored private let transformerProvider: any TransformerSnapshotting
    @ObservationIgnored private let pasteboard: any PasteboardWriting
    @ObservationIgnored private let feedback: any AppFeedbackProviding
    @ObservationIgnored private let metrics: any PipelineMetricsRecording
    @ObservationIgnored private let delivery: DeliveryCoordinator
    @ObservationIgnored private var preparedHotkeyLocaleIDs: Set<String> = []
    @ObservationIgnored private let captureDeliveryTarget: @MainActor (pid_t?) async -> DeliveryTarget?
    @ObservationIgnored private let frontmostApplication: @MainActor (Bool) -> (bundleID: String?, processID: pid_t?)
    @ObservationIgnored private let selectionReader: any SelectionReading
    @ObservationIgnored private let errorResetDelayNanoseconds: UInt64
    @ObservationIgnored private let errorResetSleeper: ErrorResetSleeper
    @ObservationIgnored private let feedbackFlashDurationNanoseconds: UInt64
    @ObservationIgnored private let feedbackFlashSleeper: FeedbackFlashSleeper
    @ObservationIgnored private let maximumRecordingDurationNanoseconds: UInt64?
    @ObservationIgnored private let recordingDurationSleeper: RecordingDurationSleeper
    @ObservationIgnored private let recordingClock: any RecordingClock
    @ObservationIgnored private let processActivity: any ProcessActivityControlling
    @ObservationIgnored private let outputDucker: OutputDucker?
    @ObservationIgnored private var outputVolumeWork: Task<Void, Never>?
    /// Recordings still being filed or discarded after their run ended, keyed by recording ID.
    @ObservationIgnored private var recordingWork: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private let streamingTypistFactory: () -> any StreamingTyping
    @ObservationIgnored private var activeRun: PipelineRun?
    @ObservationIgnored var foregroundActivityChanged: ((Bool) -> Void)?
    private var activeRunID: UUID? { activeRun?.id }
    private var isRevisionRun: Bool { activeRun?.configuration.purpose.isRevision == true }
    @ObservationIgnored private var errorResetTask: Task<Void, Never>?
    @ObservationIgnored private var errorResetRunID: UUID?
    @ObservationIgnored private var feedbackFlashTask: Task<Void, Never>?
    @ObservationIgnored private var hotkeyController: HotkeyController?
    @ObservationIgnored private let recordingCue: (any RecordingCuePresenting)?
    @ObservationIgnored let recordingArchive: (any RecordingArchiving)?
    @ObservationIgnored private var didNotifyEmptySelectionContext = false
    @ObservationIgnored private var didNotifySpeechEngineFallback = false
    @ObservationIgnored private var didNotifyUntrustedSelectionContext = false
    @ObservationIgnored private var didRequestSelectionAccessibilityTrust = false

    init(
        settings: AppSettings = AppSettings(),
        transcriberAssetManager: TranscriberAssetManager = TranscriberAssetManager(),
        history: HistoryStore? = nil,
        keychainStore: KeychainStore = KeychainStore(),
        audioRecorder: (any AudioRecording)? = nil,
        transcriber: (any Transcriber)? = nil,
        speechModels: [SpeechEngine: InstalledSpeechModel] = [:],
        usageStats: UsageStatsStore? = nil,
        transformer: (any TextTransformer)? = nil,
        transformerProvider: (any TransformerSnapshotting)? = nil,
        pasteboard: any PasteboardWriting = ClipboardWriter(),
        feedback: any AppFeedbackProviding = AppFeedback(),
        metrics: any PipelineMetricsRecording = PipelineMetricsRecorder(),
        autoPaster: any AutoPasting = AutoPaster(),
        streamingTypistFactory: @escaping () -> any StreamingTyping = { StreamingTypist() },
        errorResetDelayNanoseconds: UInt64 = 4_000_000_000,
        errorResetSleeper: @escaping ErrorResetSleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        feedbackFlashDurationNanoseconds: UInt64 = 1_000_000_000,
        feedbackFlashSleeper: @escaping FeedbackFlashSleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        maximumRecordingDurationNanoseconds: UInt64? = nil,
        recordingDurationSleeper: @escaping RecordingDurationSleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        autoPasteDelayNanoseconds: UInt64 = 50_000_000,
        autoPasteSleeper: @escaping AutoPasteSleeper = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        recordingClock: any RecordingClock = ContinuousRecordingClock(),
        processActivity: any ProcessActivityControlling = ProcessInfo.processInfo,
        installHotkeys: Bool = false,
        selectionReader: any SelectionReading = SelectionReader(),
        recordingCue: (any RecordingCuePresenting)? = nil,
        recordingArchive: (any RecordingArchiving)? = nil,
        outputDucker: OutputDucker? = nil,
        frontmostApplication: @escaping @MainActor (Bool) -> (bundleID: String?, processID: pid_t?) = { includeBundleID in
            let app = NSWorkspace.shared.frontmostApplication
            return (includeBundleID ? app?.bundleIdentifier : nil, app?.processIdentifier)
        },
        captureDeliveryTarget: @escaping @MainActor (pid_t?) async -> DeliveryTarget? = { await DeliveryTarget.capture(processID: $0) }
    ) {
        self.settings = settings
        self.transcriberAssetManager = transcriberAssetManager
        self.history = history ?? HistoryStore(persistenceEnabled: settings.persistHistory)
        self.keychainStore = keychainStore
        self.audioRecorder = audioRecorder ?? AudioRecorder(settings: settings)
        self.transcriber = transcriber ?? AppleTranscriber(assetManager: transcriberAssetManager)
        self.speechModels = speechModels
        self.usageStats = usageStats ?? UsageStatsStore()
        if let transformerProvider {
            self.transformerProvider = transformerProvider
        } else if let transformer {
            self.transformerProvider = StaticTransformerProvider(transformer: transformer)
        } else {
            self.transformerProvider = AppSettingsTransformerProvider(
                settings: settings,
                keychainStore: keychainStore
            )
        }
        self.pasteboard = pasteboard
        self.feedback = feedback
        self.metrics = metrics
        self.autoPaster = autoPaster
        self.captureDeliveryTarget = captureDeliveryTarget
        self.frontmostApplication = frontmostApplication
        self.selectionReader = selectionReader
        self.streamingTypistFactory = streamingTypistFactory
        self.delivery = DeliveryCoordinator(
            autoPaster: autoPaster,
            feedback: feedback,
            metrics: metrics,
            streamingTypistFactory: streamingTypistFactory,
            autoPasteDelayNanoseconds: autoPasteDelayNanoseconds,
            autoPasteSleeper: autoPasteSleeper,
            captureDeliveryTarget: captureDeliveryTarget,
            frontmostApplication: frontmostApplication
        )
        self.errorResetDelayNanoseconds = errorResetDelayNanoseconds
        self.errorResetSleeper = errorResetSleeper
        self.feedbackFlashDurationNanoseconds = feedbackFlashDurationNanoseconds
        self.feedbackFlashSleeper = feedbackFlashSleeper
        self.maximumRecordingDurationNanoseconds = maximumRecordingDurationNanoseconds
        self.recordingDurationSleeper = recordingDurationSleeper
        self.recordingClock = recordingClock
        self.processActivity = processActivity
        self.recordingCue = recordingCue
        self.recordingArchive = recordingArchive
        self.outputDucker = outputDucker

        if let appFeedback = feedback as? AppFeedback {
            appFeedback.actionHandler = self
        }

        if installHotkeys {
            self.installHotkeys()
        }
    }

    func installHotkeys(registration: any HotkeyRegistering = SystemHotkeyRegistration()) {
        guard hotkeyController == nil else { return }

        let controller = HotkeyController(appState: self, registration: registration)
        hotkeyController = controller
        controller.setCancelShortcutEnabled(pipelineState.allowsCancelShortcut)
        refreshWorkflowHotkeys()
    }

    private var holdsPasteNow: Bool {
        holdsPasteForOnboarding && frontmostApplication(false).processID == ProcessInfo.processInfo.processIdentifier
    }

    func refreshWorkflowHotkeys() {
        hotkeyController?.setFnKeyEnabled(settings.dictateWithFnKey)
        hotkeyController?.rebuildWorkflowShortcuts(
            workflowIDs: settings.workflowList.workflows.map(\.id)
        )
        prepareBoundSpeechModels()
    }

    func refreshDictationLocales() async {
        if let replacementLocaleID = await transcriberAssetManager.refreshSupportedLocales(
            selecting: settings.activeWorkflow.dictationLocaleID
        ) {
            settings.updateWorkflow(id: settings.activeWorkflow.id) { workflow in
                workflow.dictationLocaleID = replacementLocaleID
            }
        }

        transcriberAssetManager.prepareSelectedLocale(settings.activeWorkflow.dictationLocaleID)
        prepareBoundSpeechModels()
    }

    var isMenuBarSymbolAnimated: Bool {
        switch pipelineState {
        case .recording, .transcribing, .translating:
            true
        case .idle, .error:
            false
        }
    }

    private func syncRecordingCue() {
        guard let recordingCue else { return }
        guard settings.showRecordingCue else {
            recordingCue.apply(.hidden)
            return
        }

        let state: RecordingCueState = switch pipelineState {
        case .recording:
            .recording(caption: recordingCueCaption)
        case .transcribing, .translating:
            .processing
        case .error(let message):
            .error(message)
        case .idle:
            isShowingSuccessFeedback ? .success : .hidden
        }
        recordingCue.apply(state)
    }

    private var recordingCueCaption: String? {
        if isRevisionRun {
            return "Revising last result"
        }

        guard let workflowID = activeRun?.configuration.workflowID,
              workflowID != settings.activeWorkflow.id,
              let workflow = settings.workflowList.workflows.first(where: { $0.id == workflowID })
        else {
            return nil
        }
        return workflow.name
    }

    var menuBarSymbol: String {
        Self.menuBarSymbol(for: pipelineState, showingSuccess: isShowingSuccessFeedback)
    }

    static func menuBarSymbol(for state: PipelineState, showingSuccess: Bool) -> String {
        switch state {
        case .idle:
            showingSuccess ? "checkmark.circle" : "waveform"
        case .recording:
            "waveform.badge.microphone"
        case .transcribing, .translating:
            "ellipsis"
        case .error:
            "exclamationmark.triangle"
        }
    }

    // MARK: - Events

    private func command(for event: PipelineEvent) -> PipelineCommand {
        PipelineTransitions.command(
            for: event, in: pipelineState,
            run: activeRun?.traits, hasLastResult: lastResult != nil
        )
    }

    private func perform(_ command: PipelineCommand, stopReason: RunStopReason = .hotkey) {
        switch command {
        case .ignore:
            break
        case .startRun(let workflowID):
            startRun(workflowID: workflowID)
        case .startRevision:
            startRevision()
        case .stopRecording:
            requestStopRecording(stopReason)
        case .cancelRun:
            cancelActiveRun()
        }
    }

    func triggerPressed(workflowID: UUID? = nil) {
        guard isHotkeyPaused == false else { return }
        perform(command(for: .triggerPressed(workflowID: workflowID)))
    }

    func triggerReleased(workflowID: UUID? = nil) {
        guard isHotkeyPaused == false else { return }
        perform(command(for: .triggerReleased(workflowID: workflowID)))
    }

    func revisionTriggerPressed() {
        guard isHotkeyPaused == false else { return }
        perform(command(for: .revisionPressed))
    }

    func revisionTriggerReleased() {
        guard isHotkeyPaused == false else { return }
        perform(command(for: .revisionReleased))
    }

    var revisionMenuActionTitle: String {
        pipelineState == .recording && isRevisionRun ? "Finish revision" : "Revise last result"
    }

    var canPerformRevisionMenuAction: Bool {
        command(for: .revisionMenu) != .ignore
    }

    func performRevisionMenuAction() {
        perform(command(for: .revisionMenu), stopReason: .menu)
    }

    func cancelRequested() {
        perform(command(for: .cancel))
    }

    func startRevision() {
        guard pipelineState.acceptsNewRun, let baseOutput = lastResult else { return }
        let activeConfiguration = settings.runConfiguration(workflowID: nil)

        let configuration = RunConfiguration(
            workflowID: activeConfiguration.workflowID,
            workflowName: activeConfiguration.workflowName,
            dictationLocaleID: activeConfiguration.dictationLocaleID,
            instruction: "",
            provider: activeConfiguration.provider,
            transformation: .revision(adjustment: "", instruction: ""),
            purpose: .revision(base: baseOutput),
            speechVocabulary: activeConfiguration.speechVocabulary,
            speechEngine: activeConfiguration.speechEngine,
            corrections: activeConfiguration.corrections
        )
        startRevisionRun(configuration: configuration)
    }

    private func cancelActiveRun() {
        cancelActiveStreamingTypist()
        activeRun?.cancel()
        cancelErrorReset()
        audioRecorder.stop()
        resumeStopWaiter()
        clearRunTracking()
        pipelineState = .idle
    }

    /// Called before the app quits, including Command-Q, logout, and an update relaunch. Ends any
    /// run, puts the output volume back, and writes pending history.
    func prepareForTermination() async {
        let runTask = activeRun?.task
        if activeRun != nil || pipelineState != .idle {
            cancelActiveRun()
        }
        // A cancelled run discards its recording on the way out; a finished one may still be filing
        // its recording for learning. Both get a bounded wait so quitting never hangs.
        let pending = [runTask].compactMap { $0 } + Array(recordingWork.values) + [outputVolumeWork].compactMap { $0 }
        if pending.isEmpty == false {
            _ = try? await withOperationTimeout(.seconds(2), error: CancellationError()) {
                for task in pending { await task.value }
            }
        }
        await usageStats.flush()
        await history.flush()
    }

    // MARK: - Results

    var lastResult: String? {
        history.records.first { record in
            guard record.output != nil else { return false }
            if case .success = record.outcome { return true }
            if case .failed = record.outcome,
               case .revision = record.transformation {
                return true
            }
            return false
        }?.output
    }

    private var lastSuccessfulResult: String? {
        history.records.first { record in
            guard record.output != nil else { return false }
            if case .success = record.outcome { return true }
            return false
        }?.output ?? lastResult
    }

    var transcriptFallback: String? {
        guard let record = history.records.first,
              record.canUseTranscriptFallback else {
            return nil
        }
        return record.transcript
    }

    var canCopyTranscriptFallback: Bool {
        transcriptFallback != nil && pipelineState.acceptsNewRun
    }

    var canCopyLastResult: Bool {
        lastSuccessfulResult != nil && pipelineState.acceptsNewRun
    }

    var canCopyPendingResult: Bool {
        pendingClipboardResult != nil && pipelineState.acceptsNewRun
    }

    func copyPendingResult() {
        guard canCopyPendingResult, let result = pendingClipboardResult else { return }
        copyToClipboard(result.delivered) {
            appendRecord(
                transcript: result.transcript,
                output: result.output,
                transformation: result.transformation,
                outcome: .success,
                provider: result.provider
            )
            pendingClipboardResult = nil
        }
    }

    func copyTranscriptFallback(recordID: UUID? = nil) {
        guard pipelineState.acceptsNewRun,
              let record = recordID.flatMap({ id in history.records.first { $0.id == id } }) ?? (recordID == nil ? history.records.first : nil),
              record.canUseTranscriptFallback else {
            return
        }

        copyToClipboard(record.transcript) {
            appendRecord(
                transcript: record.transcript,
                output: record.transcript,
                transformation: record.transformation,
                outcome: .success,
                provider: record.provider
            )
        }
    }

    func copyHistoryRecord(recordID: UUID) {
        guard pipelineState.acceptsNewRun,
              let record = history.records.first(where: { $0.id == recordID }),
              record.canCopyFromHistory else {
            return
        }
        copyToClipboard(record.output ?? record.transcript)
    }

    func copyLastResult() {
        guard canCopyLastResult, let text = lastSuccessfulResult else { return }
        copyToClipboard(text)
    }

    /// The one path for explicit copy actions: write, record, and confirm, or show why it failed.
    private func copyToClipboard(_ text: String, afterWrite: () -> Void = {}) {
        do {
            try pasteboard.write(text)
            afterWrite()
            cancelErrorReset()
            pipelineState = .idle
            showSuccessFeedback()
        } catch {
            presentError(error)
            scheduleErrorReset(for: UUID())
        }
    }

    func pasteLastResult() async {
        guard canCopyLastResult, let text = lastSuccessfulResult else { return }
        let pasteID = UUID()
        pendingPasteID = pasteID
        defer { if pendingPasteID == pasteID { pendingPasteID = nil } }
        let pinsTarget = settings.pinDeliveryTarget
        let usesSpacing = settings.autoPasteEnabled && settings.smartSpacingEnabled
        let fitsSentence = settings.matchesSentenceAtCaret && autoPaster.isTrusted
        let target = (pinsTarget || usesSpacing || fitsSentence) ? await captureDeliveryTarget(frontmostApplication(false).processID) : nil
        guard pendingPasteID == pasteID, canCopyLastResult, !Task.isCancelled else { return }
        var context: CaretContext?
        if fitsSentence, let target {
            context = await target.caretContext(readsSentence: true)
            guard pendingPasteID == pasteID, canCopyLastResult, !Task.isCancelled else { return }
        }
        let delivered = context.map {
            SentenceFit.apply(text, context: $0, protectedTerms: settings.glossaryList.terms.map(\.term))
        } ?? text
        do {
            try pasteboard.write(delivered)
            try await delivery.pasteCompletedText(delivered, contextTarget: usesSpacing ? target : nil,
                                                  usesSpacing: usesSpacing, knownContext: context, canContinue: { [weak self] in
                self?.pendingPasteID == pasteID && self?.canCopyLastResult == true
            }, targetIsCurrent: { !pinsTarget || target?.isCurrent() == true })
        } catch is CancellationError {
        } catch {
            presentError(error)
            scheduleErrorReset(for: UUID())
        }
    }

    // MARK: - Starting runs

    private func beginRun(_ run: PipelineRun, state: PipelineState) {
        cancelErrorReset()
        cancelSuccessFeedback()
        clearRunTracking()
        activeRun = run
        foregroundActivityChanged?(true)
        pipelineState = state
    }

    private func startRun(workflowID: UUID? = nil) {
        let foreground = frontmostApplication(workflowID == nil && settings.workflowList.appRouting.isEmpty == false)
        let resolvedID = workflowID ?? settings.workflowList.routedWorkflowID(for: foreground.bundleID)
        let workflow = resolvedID.flatMap { id in
            settings.workflowList.workflows.first { $0.id == id }
        } ?? settings.activeWorkflow

        cancelErrorReset()
        cancelSuccessFeedback()
        clearRunTracking()

        let initialConfiguration = settings.runConfiguration(workflowID: workflow.id)
        let run = PipelineRun(
            configuration: initialConfiguration,
            triggerWorkflowID: workflowID,
            triggeredAt: recordingClock.now,
            settings: settings,
            holdsPaste: holdsPasteNow,
            activities: processActivity,
            isVoiceInput: workflow.input == .voice,
            providerSnapshot: initialConfiguration.purpose.isTransformation ? transformerProvider.snapshot(for: initialConfiguration.provider) : nil,
            speechModel: workflow.input == .voice ? speechModelSelection(for: initialConfiguration) : (nil, nil)
        )
        let prepareAfterSelection = workflow.includeSelectionContext && run.configuration.provider == .appleOnDevice
        let context = RunContextRequest(
            workflow: workflow, foregroundPID: foreground.processID,
            glossary: settings.glossaryList,
            dictation: settings.dictationOptions(input: workflow.input, provider: initialConfiguration.provider),
            prepareAfterSelection: prepareAfterSelection
        )
        beginRun(run, state: workflow.input == .voice ? .recording : .translating)
        if prepareAfterSelection == false { prepareTransformer(for: run) }
        let runID = run.id

        switch workflow.input {
        case .voice:
            metrics.begin(.hotkeyToRecordingStarted, runID: runID)
            scheduleRecordingDurationLimit(for: runID)
            // The microphone opens first. Selection and editor reads run beside it, so a slow
            // Accessibility reply never costs the first words of the dictation.
            let resolved = Task { [weak self] () -> RunConfiguration? in
                await self?.resolveRunContext(run, context)
            }
            run.task = Task { [weak self] in
                await self?.runPipeline(runID: runID, resolvedConfiguration: resolved)
            }
        case .selection:
            run.task = Task { [weak self] in
                guard let self, let configuration = await resolveRunContext(run, context) else { return }
                await runSelectionPipeline(runID: runID, configuration: configuration)
            }
        }
    }

    private struct RunContextRequest {
        let workflow: Workflow
        let foregroundPID: pid_t?
        let glossary: GlossaryList
        /// Read at the trigger with the rest of the run's settings, not after the selection read.
        let dictation: DictationOptions
        let prepareAfterSelection: Bool
    }

    /// Reads the selection a workflow asked for and the editor to deliver into, then builds the run's
    /// final configuration. Returns nil when the run ended or could not start.
    private func resolveRunContext(_ run: PipelineRun, _ request: RunContextRequest) async -> RunConfiguration? {
        let runID = run.id
        let workflow = request.workflow
        guard isCurrentRun(runID), Task.isCancelled == false else { return nil }

        var contextText: String?
        if workflow.input == .selection || workflow.includeSelectionContext {
            metrics.begin(.selectionCapture, runID: runID)
            let capture = await selectionReader.captureForRun(processID: request.foregroundPID)
            guard isCurrentRun(runID), Task.isCancelled == false else { return nil }
            metrics.end(.selectionCapture, runID: runID)

            if run.needsDeliveryTarget {
                run.deliveryTarget = capture.source
            }
            switch (workflow.input, capture.selection) {
            case (_, .text(let text)):
                contextText = text
            case (.voice, .empty):
                if didNotifyEmptySelectionContext == false {
                    didNotifyEmptySelectionContext = true
                    feedback.notifyError(message: "No selected text — ran without context")
                }
            case (.voice, .notTrusted):
                if didNotifyUntrustedSelectionContext == false {
                    didNotifyUntrustedSelectionContext = true
                    feedback.notifyError(
                        message: "No selected text — grant Accessibility to attach context"
                    )
                }
            case (.selection, .empty):
                failRunStart(PipelineError.noSelectedText, runID: runID)
                return nil
            case (.selection, .notTrusted):
                if didRequestSelectionAccessibilityTrust == false {
                    didRequestSelectionAccessibilityTrust = true
                    autoPaster.requestTrust()
                }
                failRunStart(PipelineError.selectionAccessibilityRequired, runID: runID)
                return nil
            case (.voice, .sourceChanged):
                feedback.notifyError(message: "The selected editor changed - ran without context.")
            case (.selection, .sourceChanged):
                failRunStart(PipelineError.selectionSourceChanged, runID: runID)
                return nil
            }
        }

        if run.needsDeliveryTarget, run.deliveryTarget == nil {
            run.deliveryTarget = await captureDeliveryTarget(request.foregroundPID)
        }
        guard isCurrentRun(runID), Task.isCancelled == false else { return nil }

        let base = run.configuration
        let hasContext = workflow.input == .voice && workflow.includeSelectionContext && contextText != nil
        let configuration = RunConfiguration(
            workflowID: base.workflowID, workflowName: base.workflowName,
            dictationLocaleID: base.dictationLocaleID,
            instruction: PromptBuilder.instruction(
                for: workflow.kind, glossary: request.glossary, context: hasContext ? contextText : nil,
                dictation: request.dictation
            ),
            provider: base.provider,
            transformation: workflow.input == .selection || hasContext
                ? .contextual(workflowName: base.workflowName, instruction: base.instruction) : base.transformation,
            purpose: base.purpose, contextText: contextText, speechVocabulary: base.speechVocabulary,
            speechEngine: base.speechEngine, corrections: base.corrections
        )
        if request.prepareAfterSelection { prepareTransformer(for: run, instruction: configuration.instruction) }
        return configuration
    }

    private func startRevisionRun(configuration: RunConfiguration) {
        let run = PipelineRun(
            configuration: configuration,
            triggerWorkflowID: nil,
            triggeredAt: recordingClock.now,
            settings: settings,
            holdsPaste: holdsPasteNow,
            activities: processActivity,
            providerSnapshot: configuration.purpose.isTransformation ? transformerProvider.snapshot(for: configuration.provider) : nil,
            speechModel: speechModelSelection(for: configuration)
        )
        beginRun(run, state: .recording)
        let runID = run.id
        metrics.begin(.hotkeyToRecordingStarted, runID: runID)
        scheduleRecordingDurationLimit(for: runID)
        let foregroundPID = frontmostApplication(false).processID
        prepareTransformer(for: run)
        let resolved = Task { [captureDeliveryTarget] () -> RunConfiguration? in
            if run.needsDeliveryTarget {
                run.deliveryTarget = await captureDeliveryTarget(foregroundPID)
            }
            return configuration
        }
        run.task = Task { [weak self] in
            await self?.runPipeline(runID: runID, resolvedConfiguration: resolved)
        }
    }

    private func prepareTransformer(for run: PipelineRun, instruction: String? = nil) {
        if case .transcribeOnly = run.configuration.purpose { return }
        metrics.begin(.translationConfiguration, runID: run.id)
        let provider = run.providerSnapshot ?? transformerProvider.snapshot(for: run.configuration.provider)
        run.preparedTransformer = Task { [metrics] in
            let transformer = await provider.transformer(instruction: instruction ?? run.configuration.instruction)
            metrics.end(.translationConfiguration, runID: run.id)
            if let failed = transformer as? FailedTextTransformer {
                recordingFailed(failed.error, runID: run.id)
            }
            return transformer
        }
    }

    // MARK: - Pipelines

    private func runSelectionPipeline(
        runID: UUID,
        configuration: RunConfiguration
    ) async {
        do {
            guard isCurrentRun(runID), let selectedText = configuration.contextText else {
                throw CancellationError()
            }
            try Task.checkCancellation()

            _ = try await translateAndDeliver(
                inputText: selectedText,
                transcript: selectedText,
                recordTranscript: "",
                configuration: configuration,
                runID: runID
            )
            finishRunSucceeded(runID)
        } catch {
            finishRunFailed(runID, error: error)
        }
    }

    private func runPipeline(
        runID: UUID,
        resolvedConfiguration: Task<RunConfiguration?, Never>
    ) async {
        var transcriptionTask: Task<String, any Error>?
        var appleTranscriptionTask: Task<String, any Error>?
        var transformerTask: Task<any TextTransformer, Never>?
        var provisionalRecordingID: UUID?
        var recordingTeeSession: RecordingTeeSession?
        defer {
            resolvedConfiguration.cancel()
            transcriptionTask?.cancel()
            appleTranscriptionTask?.cancel()
            transformerTask?.cancel()
        }

        do {
            guard let run = activeRun, run.id == runID else { return }
            try Task.checkCancellation()
            if let failure = run.failure { throw failure }

            audioRecorder.onFailure = { [weak self] error in
                self?.recordingFailed(error, runID: runID)
            }
            let rawAudio = try await audioRecorder.start()
            let levelCue = run.showRecordingCue ? recordingCue : nil
            var audio = AudioLevelTap.attach(to: rawAudio, onOverflow: { [weak self] in
                Task { @MainActor in self?.recordingFailed(AudioRecordingError.audioBufferOverflow, runID: runID) }
            }) { [weak self, weak levelCue] level in
                Task { @MainActor in
                    guard self?.isCurrentRun(runID) == true else { return }
                    levelCue?.updateLevel(level.smoothed)
                    self?.receiveBufferLevel(dBFS: level.dBFS, runID: runID)
                }
            }
            if let capture = run.pauseAudio {
                audio = capture.attach(to: audio) { [weak run] in
                    run?.pauseCheckTask?.cancel()
                    run?.pauseCheckTask = nil
                }
            }
            if settings.glossaryLearningEnabled, let recordingArchive {
                do {
                    let fileURL = try await recordingArchive.beginEntry(id: runID)
                    provisionalRecordingID = runID
                    let session = RecordingTee.attach(to: audio, fileURL: fileURL, onOverflow: { [weak self] in
                        Task { @MainActor in self?.recordingFailed(AudioRecordingError.audioBufferOverflow, runID: runID) }
                    })
                    recordingTeeSession = session
                    audio = session.stream
                } catch {
                    // Archiving is best-effort and must never fail a dictation. A pending cleanup
                    // also refuses new entries here, so retention caps stay enforceable.
                }
            }
            guard isCurrentRun(runID) else {
                throw CancellationError()
            }
            metrics.end(.hotkeyToRecordingStarted, runID: runID)
            if run.lowersOtherAudio {
                changeOutputVolume { try await $0.lower() }
            }
            try Task.checkCancellation()

            // Audio is already buffering. The selection and editor reads finish here, before the
            // instruction is used by transcription vocabulary or an early transformation.
            let resolved = await withTaskCancellationHandler {
                await resolvedConfiguration.value
            } onCancel: {
                resolvedConfiguration.cancel()
            }
            guard let configuration = resolved, isCurrentRun(runID) else { throw CancellationError() }
            try Task.checkCancellation()

            transformerTask = run.preparedTransformer
            run.transformationInstruction = configuration.instruction
            let locale = Locale(identifier: configuration.dictationLocaleID)
            metrics.begin(.transcriptionWindow, runID: runID)
            var onPartialTranscript: (@Sendable (String) -> Void)?
            if recordingCue != nil && run.showRecordingCue && run.showLiveTranscript {
                onPartialTranscript = { [weak self] text in
                    Task { @MainActor in
                        guard let self, self.isCurrentRun(runID) else { return }
                        if run.showRecordingCue && run.showLiveTranscript {
                            self.recordingCue?.updateTranscript(text)
                        }
                    }
                }
            }
            let speechModel = run.speechModel
            if let parakeetTranscriber = speechModel.transcriber {
                let (previewAudio, finalAudio) = AudioFanOut.split(audio)
                let streams = configuration.speechEngine.isStreaming
                let preview = Task {
                    try await transcriber.transcribe(previewAudio, request: TranscriptionRequest(
                        locale: locale, vocabulary: configuration.speechVocabulary,
                        onPartialTranscript: streams ? nil : onPartialTranscript, preferFastResults: true
                    ))
                }
                appleTranscriptionTask = preview
                transcriptionTask = Task {
                    let parakeetText: String?
                    do {
                        parakeetText = try await parakeetTranscriber.transcribe(finalAudio, request: TranscriptionRequest(
                            locale: locale, vocabulary: configuration.speechVocabulary,
                            onPartialTranscript: streams ? onPartialTranscript : nil
                        ))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        parakeetText = nil
                    }
                    if let parakeetText, parakeetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                        return parakeetText
                    }
                    do {
                        return try await withTaskCancellationHandler {
                            try await preview.value
                        } onCancel: {
                            preview.cancel()
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch _ where parakeetText != nil {
                        return ""
                    } catch {
                        recordingFailed(error, runID: runID)
                        throw error
                    }
                }
            } else {
                transcriptionTask = Task {
                    do {
                        return try await transcriber.transcribe(audio, request: TranscriptionRequest(
                            locale: locale, vocabulary: configuration.speechVocabulary,
                            onPartialTranscript: onPartialTranscript, preferFastResults: run.preferFastTranscription
                        ))
                    } catch {
                        recordingFailed(error, runID: runID)
                        throw error
                    }
                }
            }
            try Task.checkCancellation()

            await waitForStopRecording()
            guard isCurrentRun(runID) else { throw CancellationError() }
            try Task.checkCancellation()

            if let failure = run.failure { throw failure }
            try await audioRecorder.finish()
            guard isCurrentRun(runID) else { throw CancellationError() }
            metrics.end(.releaseToRecorderStopped, runID: runID)
            if run.lowersOtherAudio {
                changeOutputVolume { try await $0.restore() }
            }
            pipelineState = .transcribing

            guard let activeTranscriptionTask = transcriptionTask else {
                throw CancellationError()
            }
            let transcript = try await withTaskCancellationHandler {
                try await activeTranscriptionTask.value
            } onCancel: {
                activeTranscriptionTask.cancel()
            }
            metrics.end(.transcriptionWindow, runID: runID)
            metrics.end(.releaseToTranscript, runID: runID)
            transcriptionTask = nil
            if provisionalRecordingID == nil {
                appleTranscriptionTask?.cancel()
                appleTranscriptionTask = nil
            }
            guard isCurrentRun(runID) else { throw CancellationError() }
            try Task.checkCancellation()

            if let failure = run.failure { throw failure }
            let rawTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTranscript = PauseTransformation.input(transcript, corrections: configuration.corrections)
            guard trimmedTranscript.isEmpty == false else {
                throw PipelineError.emptyTranscript
            }
            if let notice = speechModel.fallbackNotice, didNotifySpeechEngineFallback == false {
                didNotifySpeechEngineFallback = true
                feedback.notifyError(message: notice)
            }
            let transformationInput: String
            let resolvedConfiguration: RunConfiguration
            switch configuration.purpose {
            case .dictation, .transcribeOnly:
                transformationInput = trimmedTranscript
                resolvedConfiguration = configuration
            case .revision(let base):
                let instruction = PromptBuilder.compose(
                    base: PromptBuilder.revisionInstruction(adjustment: trimmedTranscript),
                    glossary: run.glossaryBlock,
                    context: nil,
                    contract: PromptBuilder.outputContract
                )
                transformationInput = base
                resolvedConfiguration = RunConfiguration(
                    workflowID: configuration.workflowID,
                    workflowName: configuration.workflowName,
                    dictationLocaleID: configuration.dictationLocaleID,
                    instruction: instruction,
                    provider: configuration.provider,
                    transformation: .revision(
                        adjustment: trimmedTranscript,
                        instruction: instruction
                    ),
                    purpose: configuration.purpose,
                    contextText: configuration.contextText,
                    speechVocabulary: configuration.speechVocabulary,
                    speechEngine: configuration.speechEngine
                )
            }

            if case .transcribeOnly(let cleanup, let symbols) = resolvedConfiguration.purpose {
                let output = TranscriptCleanup.apply(trimmedTranscript, localeID: configuration.dictationLocaleID,
                                                     cleanup: cleanup, spokenSymbols: symbols)
                guard output.isEmpty == false else { throw PipelineError.emptyTranscript }
                try Task.checkCancellation()
                _ = try await commitAtomicOutput(output, transcript: trimmedTranscript, configuration: configuration,
                                                 runID: runID, recordReleaseToClipboard: true)
            } else {
                pipelineState = .translating
                let earlyOutput = try await pauseTransformationOutput(for: transformationInput, run: run)
                if let earlyOutput {
                    _ = try await commitAtomicOutput(earlyOutput, transcript: trimmedTranscript,
                        configuration: resolvedConfiguration, runID: runID, recordReleaseToClipboard: true)
                } else {
                    _ = try await translateAndDeliver(
                        inputText: transformationInput,
                        transcript: trimmedTranscript,
                        configuration: resolvedConfiguration,
                        runID: runID,
                        preparedTransformerTask: transformerTask,
                        recordReleaseToClipboard: true
                    )
                }
            }
            transformerTask = nil
            recordUsage(rawTranscript: rawTranscript, transcript: trimmedTranscript, configuration: configuration, run: run)
            if let recordingID = provisionalRecordingID, let recordingArchive {
                let tee = recordingTeeSession
                let appleTranscription = appleTranscriptionTask
                appleTranscriptionTask = nil
                recordingWork[recordingID] = Task { [weak self, settings] in
                    defer { self?.recordingWork[recordingID] = nil }
                    let archived = await tee?.waitForCompletion() ?? false
                    let appleTranscript = if let appleTranscription {
                        ((try? await appleTranscription.value) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        rawTranscript
                    }
                    if archived, settings.glossaryLearningEnabled, appleTranscript.isEmpty == false {
                        await recordingArchive.commitEntry(id: recordingID, localeID: configuration.dictationLocaleID, appleTranscript: appleTranscript)
                    } else {
                        await recordingArchive.discardEntry(id: recordingID)
                    }
                }
            }
            provisionalRecordingID = nil

            if run.lowersOtherAudio, let outputVolumeWork {
                _ = try? await withOperationTimeout(.seconds(1), error: CancellationError()) {
                    await outputVolumeWork.value
                }
            }
            finishRunSucceeded(runID)
        } catch {
            if isCurrentRun(runID) {
                audioRecorder.stop()
            }
            await recordingTeeSession?.cancelAndWait()
            if let provisionalRecordingID {
                await recordingArchive?.discardEntry(id: provisionalRecordingID)
            }
            finishRunFailed(runID, error: error)
        }
    }

    private func finishRunSucceeded(_ runID: UUID) {
        guard isCurrentRun(runID) else { return }
        pipelineState = .idle
        showSuccessFeedback()
        finishRun(runID)
    }

    /// Cancellation ends quietly; any other error is shown and clears itself after a delay.
    private func finishRunFailed(_ runID: UUID, error: any Error) {
        guard isCurrentRun(runID) else { return }
        if error is CancellationError {
            cancelSuccessFeedback()
            pipelineState = .idle
            finishRun(runID)
        } else {
            presentError(error)
            scheduleErrorReset(for: runID)
            finishRun(runID, keepErrorReset: true)
        }
    }

    /// Counts only. The transcript is measured here and goes no further.
    private func recordUsage(rawTranscript: String, transcript: String, configuration: RunConfiguration, run: PipelineRun) {
        guard settings.keepsUsageStats else { return }
        var fixes = Correction.replacementCount(configuration.corrections, in: rawTranscript)
        switch configuration.purpose {
        case .revision:
            return
        case .transcribeOnly(let cleanup, _):
            if cleanup {
                fixes += TranscriptCleanup.fillerCount(in: transcript, localeID: configuration.dictationLocaleID)
            }
        case .dictation:
            break
        }
        let recorded = run.voicedDuration > .zero
            ? run.voicedDuration
            : run.releasedAt.map { run.triggeredAt.duration(to: $0) } ?? .zero
        let parts = recorded.components
        let frontmost = frontmostApplication(true).bundleID
        usageStats.record(
            words: UsageStats.wordCount(in: transcript),
            seconds: Double(parts.seconds) + Double(parts.attoseconds) / 1e18,
            fixes: fixes,
            appBundleID: frontmost == Bundle.main.bundleIdentifier ? nil : frontmost
        )
    }

    // MARK: - Transformation and delivery

    private func translateAndDeliver(
        inputText: String,
        transcript: String,
        recordTranscript: String? = nil,
        configuration: RunConfiguration,
        runID: UUID,
        preparedTransformerTask: Task<any TextTransformer, Never>? = nil,
        recordReleaseToClipboard: Bool = false
    ) async throws -> String {
        guard isCurrentRun(runID) else { throw CancellationError() }
        try Task.checkCancellation()
        let transformerTask: Task<any TextTransformer, Never>
        if let preparedTransformerTask = preparedTransformerTask ?? activeRun?.preparedTransformer {
            transformerTask = preparedTransformerTask
        } else {
            metrics.begin(.translationConfiguration, runID: runID)
            let snapshot = transformerProvider.snapshot(for: configuration.provider)
            transformerTask = Task { [metrics] in
                let transformer = await snapshot.transformer(instruction: configuration.instruction)
                await MainActor.run {
                    metrics.end(.translationConfiguration, runID: runID)
                }
                return transformer
            }
        }

        let transformer = await withTaskCancellationHandler {
            await transformerTask.value
        } onCancel: {
            transformerTask.cancel()
        }
        guard isCurrentRun(runID) else {
            throw CancellationError()
        }
        try Task.checkCancellation()

        let recordedTranscript = recordTranscript ?? transcript
        if let run = activeRun,
           (run.streamingDeliveryEnabled && run.autoPasteEnabled && autoPaster.isTrusted)
                || (run.showRecordingCue && recordingCue != nil),
           let streamingTransformer = transformer as? any StreamingTextTransformer,
           let streamedText = try await streamAndDeliver(
               inputText: inputText,
               transcript: recordedTranscript,
               configuration: configuration,
               runID: runID,
               transformer: streamingTransformer,
               recordReleaseToClipboard: recordReleaseToClipboard
           ) {
            return streamedText
        }

        let transformedText: String
        do {
            metrics.begin(.translation, runID: runID)
            transformedText = try await transformer.transform(
                inputText,
                instruction: configuration.instruction
            )
            metrics.end(.translation, runID: runID)
        } catch {
            throw recordFailedDelivery(error, transcript: recordedTranscript, inputText: inputText,
                                       configuration: configuration, runID: runID)
        }

        return try await commitAtomicOutput(transformedText, transcript: recordedTranscript,
            configuration: configuration, runID: runID, recordReleaseToClipboard: recordReleaseToClipboard)
    }

    private func commitAtomicOutput(
        _ transformedText: String, transcript: String, configuration: RunConfiguration,
        runID: UUID, recordReleaseToClipboard: Bool
    ) async throws -> String {
        guard let run = activeRun, run.id == runID else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        let fitted = await delivery.sentenceFit(for: transformedText, run: run)
        guard isCurrentRun(runID) else { throw CancellationError() }
        try Task.checkCancellation()

        try commit(
            CompletedOutput(output: transformedText, fitted: fitted, transcript: transcript, configuration: configuration),
            runID: runID, recordReleaseToClipboard: recordReleaseToClipboard
        )
        metrics.recordDeliveryMode(.atomic, runID: runID)
        try await delivery.autoPaste(fitted.text, run: run, knownContext: fitted.context,
                                     isCurrentRun: currentRunCheck(runID))
        return transformedText
    }

    /// The single commit point for every delivered result: clipboard, history, and the point after
    /// which cancel no longer applies. A failed clipboard write keeps the result for Copy Result.
    private func commit(_ completed: CompletedOutput, runID: UUID, recordReleaseToClipboard: Bool) throws {
        if let failure = activeRun?.failure { throw failure }
        metrics.begin(.clipboardWrite, runID: runID)
        do {
            try pasteboard.write(completed.fitted.text)
            pendingClipboardResult = nil
        } catch {
            pendingClipboardResult = PendingClipboardResult(
                output: completed.output,
                delivered: completed.fitted.text,
                transcript: completed.transcript,
                transformation: completed.configuration.transformation,
                provider: completed.configuration.provider
            )
            throw error
        }
        metrics.end(.clipboardWrite, runID: runID)
        if recordReleaseToClipboard {
            metrics.end(.releaseToClipboard, runID: runID)
        }

        appendRecord(
            transcript: completed.transcript,
            output: completed.output,
            transformation: completed.configuration.transformation,
            outcome: .success
        )
        activeRun?.deliveryCommitted = true
    }

    /// Records a failed transformation once, in history and on the run, and returns the error to show.
    /// When streamed text already reached the editor, the message says partial text may remain.
    private func recordFailedDelivery(
        _ error: any Error, transcript: String, inputText: String,
        configuration: RunConfiguration, runID: UUID, typist: (any StreamingTyping)? = nil
    ) -> any Error {
        let postedText = typist?.hasPostedText == true
        let deliveryError: any Error = postedText ? PipelineError.streamingFailed(userMessage(for: error)) : error
        guard isCurrentRun(runID), Task.isCancelled == false else { return deliveryError }
        activeRun?.failedRecordID = appendRecord(
            transcript: transcript,
            output: configuration.purpose.isRevision ? inputText : nil,
            transformation: configuration.transformation,
            outcome: .failed(message: userMessage(for: deliveryError))
        )
        if postedText {
            metrics.recordDeliveryMode(.streamedPartial, runID: runID)
        }
        return deliveryError
    }

    private func currentRunCheck(_ runID: UUID) -> @MainActor () -> Bool {
        { [weak self] in self?.isCurrentRun(runID) == true }
    }

    private func streamAndDeliver(
        inputText: String,
        transcript: String,
        configuration: RunConfiguration,
        runID: UUID,
        transformer: any StreamingTextTransformer,
        recordReleaseToClipboard: Bool
    ) async throws -> String? {
        guard let run = activeRun, run.id == runID else { throw CancellationError() }
        let typesIntoEditor = run.streamingDeliveryEnabled && run.autoPasteEnabled && autoPaster.isTrusted
            && delivery.targetIsCurrent(run)
        let typist: any StreamingTyping = typesIntoEditor ? streamingTypistFactory() : PreviewOnlyTypist()
        typist.setTargetValidator { [weak self, weak run] in
            guard let self, let run else { return false }
            return self.isCurrentRun(runID) && self.delivery.targetIsCurrent(run)
        }
        typist.onTextPosted = { [metrics] in metrics.end(.firstVisibleOutput, runID: runID) }
        do {
            try typist.start()
        } catch {
            return nil
        }
        let keepsWrapperQuotes = ModelOutputNormalizer.requestsQuotes(
            input: inputText,
            instruction: configuration.instruction
        )
        typist.setKeepsWrapperQuotes(keepsWrapperQuotes)
        activeRun?.streamingTypist = typist
        defer {
            clearStreamingTypistOwnership(ifOwnedBy: typist)
        }

        var fullText = ""
        var receivedFirstDelta = false
        var contextPending = typesIntoEditor && (run.smartSpacingEnabled || run.matchesSentenceAtCaret)
        var typedContext: CaretContext?
        var readTypedContext = false
        var atomicFallbackText: String?
        metrics.begin(.translation, runID: runID)
        metrics.begin(.streamingFirstDelta, runID: runID)
        metrics.begin(.firstVisibleOutput, runID: runID)

        do {
            for try await delta in transformer.transformStream(
                inputText,
                instruction: configuration.instruction
            ) {
                guard isCurrentRun(runID) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()

                if receivedFirstDelta == false {
                    receivedFirstDelta = true
                    metrics.end(.streamingFirstDelta, runID: runID)
                }
                fullText += delta
                if run.showRecordingCue, recordingCue?.updateOutput(fullText) == true {
                    metrics.end(.firstVisibleOutput, runID: runID)
                }
                if contextPending, !delta.isEmpty {
                    contextPending = false
                    let context: CaretContext?
                    if run.matchesSentenceAtCaret || delta.first?.isWhitespace == false {
                        context = await run.deliveryTarget?.caretContext(readsSentence: run.matchesSentenceAtCaret)
                    } else {
                        context = nil
                    }
                    guard isCurrentRun(runID), !Task.isCancelled else { throw CancellationError() }
                    typedContext = context
                    readTypedContext = run.matchesSentenceAtCaret
                    if run.smartSpacingEnabled, delta.first?.isWhitespace == false, context?.precedingWordCharacter == true {
                        typist.addLeadingSpace()
                    }
                    if run.matchesSentenceAtCaret, let context {
                        typist.setSentenceFit(context: context, protectedTerms: run.protectedTerms)
                    }
                }
                typist.append(delta)
            }
            metrics.end(.translation, runID: runID)
        } catch is CancellationError {
            cancelStreamingTypist(ifOwnedBy: typist)
            if typist.hasPostedText {
                metrics.recordDeliveryMode(.streamedPartial, runID: runID)
            }
            throw CancellationError()
        } catch StreamingTransformError.requiresAtomicFallback {
            cancelStreamingTypist(ifOwnedBy: typist)
            do {
                atomicFallbackText = try await transformer.transformAfterStreamingFallback(
                    inputText,
                    instruction: configuration.instruction
                )
                metrics.end(.translation, runID: runID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw recordFailedDelivery(error, transcript: transcript, inputText: inputText,
                                           configuration: configuration, runID: runID, typist: typist)
            }
        } catch {
            cancelStreamingTypist(ifOwnedBy: typist)
            throw recordFailedDelivery(error, transcript: transcript, inputText: inputText,
                                       configuration: configuration, runID: runID, typist: typist)
        }

        guard isCurrentRun(runID) else {
            cancelStreamingTypist(ifOwnedBy: typist)
            throw CancellationError()
        }
        try Task.checkCancellation()

        let transformedText: String
        if let atomicFallbackText {
            transformedText = atomicFallbackText
        } else {
            typist.finish()
            transformedText = ModelOutputNormalizer.normalize(
                fullText,
                keepsWrapperQuotes: keepsWrapperQuotes
            )
        }
        guard transformedText.isEmpty == false else {
            throw recordFailedDelivery(TranslationError.emptyResponse, transcript: transcript, inputText: inputText,
                                       configuration: configuration, runID: runID, typist: typist)
        }

        // The typist fitted what it typed with the context it read; reuse it so the clipboard matches.
        let fitted: FittedText
        if readTypedContext {
            fitted = FittedText(text: typedContext.map {
                SentenceFit.apply(transformedText, context: $0, protectedTerms: run.protectedTerms)
            } ?? transformedText, context: typedContext)
        } else {
            fitted = await delivery.sentenceFit(for: transformedText, run: run)
            guard isCurrentRun(runID) else { throw CancellationError() }
            try Task.checkCancellation()
        }

        try commit(
            CompletedOutput(output: transformedText, fitted: fitted, transcript: transcript, configuration: configuration),
            runID: runID, recordReleaseToClipboard: recordReleaseToClipboard
        )

        if typist.hasPostedText == false, (atomicFallbackText != nil || typesIntoEditor == false) {
            try await delivery.autoPaste(fitted.text, run: run, knownContext: fitted.context,
                                         isCurrentRun: currentRunCheck(runID))
        }

        if atomicFallbackText != nil {
            if typist.hasPostedText {
                metrics.recordDeliveryMode(.streamedPartial, runID: runID)
                feedback.notifyError(message: "Streaming stopped - the full result was copied.")
            } else {
                metrics.recordDeliveryMode(.atomic, runID: runID)
            }
            return transformedText
        }

        if let stopReason = typist.stopReason {
            metrics.recordDeliveryMode(.streamedPartial, runID: runID)
            delivery.notifyStreamingStopped(stopReason)
        } else {
            metrics.recordDeliveryMode(typesIntoEditor ? .streamed : .atomic, runID: runID)
        }
        return transformedText
    }

    // MARK: - Retry

    func retryTranslation(recordID: UUID) {
        guard let record = history.records.first(where: { $0.id == recordID }),
              let provider = record.provider else { return }
        retryTranslation(recordID: recordID, using: provider)
    }

    func retryTranslation(recordID: UUID, using provider: TranslationProvider) {
        guard pipelineState.acceptsNewRun,
              let record = history.records.first(where: { $0.id == recordID }),
              record.canRetry else {
            return
        }

        let inputText: String
        let purpose: RunPurpose
        switch record.transformation {
        case .revision:
            guard let baseOutput = record.output else { return }
            inputText = baseOutput
            purpose = .revision(base: baseOutput)
        case .translation, .custom, .contextual:
            inputText = record.transcript
            purpose = .dictation
        }

        let retryInstruction: String
        if case .translation(let targetLanguage, let toneInstruction) = record.transformation {
            retryInstruction = PromptBuilder.systemPrompt(
                targetLanguage: targetLanguage,
                toneInstruction: toneInstruction,
                glossary: settings.glossaryList,
                dictation: settings.dictationOptions(input: .voice, provider: provider)
            )
        } else {
            retryInstruction = record.transformation.instruction
        }
        let configuration = RunConfiguration(
            workflowID: settings.activeWorkflow.id,
            workflowName: record.transformation.displayName,
            dictationLocaleID: settings.activeWorkflow.dictationLocaleID,
            instruction: retryInstruction,
            provider: provider,
            transformation: record.transformation,
            purpose: purpose
        )
        let run = PipelineRun(
            configuration: configuration,
            triggerWorkflowID: nil,
            triggeredAt: recordingClock.now,
            settings: settings,
            holdsPaste: holdsPasteNow,
            activities: processActivity
        )
        beginRun(run, state: .translating)
        let runID = run.id

        prepareTransformer(for: run)
        let foregroundPID = frontmostApplication(false).processID
        run.task = Task { [weak self, captureDeliveryTarget] in
            if run.needsDeliveryTarget {
                run.deliveryTarget = await captureDeliveryTarget(foregroundPID)
            }
            await self?.retryPipeline(
                record: record,
                inputText: inputText,
                configuration: configuration,
                runID: runID
            )
        }
    }

    private func retryPipeline(
        record: DictationRecord,
        inputText: String,
        configuration: RunConfiguration,
        runID: UUID
    ) async {
        do {
            _ = try await translateAndDeliver(
                inputText: inputText,
                transcript: record.transcript,
                configuration: configuration,
                runID: runID,
                recordReleaseToClipboard: false
            )
            finishRunSucceeded(runID)
        } catch {
            finishRunFailed(runID, error: error)
        }
    }

    func setPersistHistory(_ isEnabled: Bool) async {
        if await history.setPersistenceEnabled(isEnabled) { settings.persistHistory = isEnabled }
    }

    @discardableResult
    private func appendRecord(
        transcript: String,
        output: String?,
        transformation: DictationRecord.TransformationSnapshot,
        outcome: DictationRecord.Outcome,
        provider: TranslationProvider? = nil
    ) -> UUID {
        let id = UUID()
        history.append(DictationRecord(
            id: id,
            finishedAt: Date.now,
            transcript: transcript,
            output: output,
            transformation: transformation,
            outcome: outcome,
            provider: {
                if case .transcribeOnly? = activeRun?.configuration.purpose { return nil }
                return provider ?? activeRun?.configuration.provider
            }(),
            duration: outcome == .success ? activeRun?.releasedAt.map { released in
                let elapsed = released.duration(to: recordingClock.now).components
                return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            } : nil
        ))
        return id
    }

    // MARK: - Recording control

    private func failRunStart(_ error: Error, runID: UUID) {
        presentError(error)
        scheduleErrorReset(for: runID)
        finishRun(runID, keepErrorReset: true)
    }

    private func recordingFailed(_ error: any Error, runID: UUID) {
        guard let run = activeRun, run.id == runID, run.deliveryCommitted == false else { return }
        if run.failure == nil { run.failure = error }
        run.cancelPauseTransformation()
        if pipelineState == .recording {
            audioRecorder.stop()
            requestStopRecording(.failure)
        }
    }

    private func waitForStopRecording() async {
        await withCheckedContinuation { continuation in
            if activeRun?.recordingPhase == .stopping {
                continuation.resume()
            } else {
                activeRun?.stopWaiter = continuation
            }
        }
    }

    private func requestStopRecording(_ reason: RunStopReason) {
        guard let run = activeRun else { return }

        switch (run.recordingPhase, reason) {
        case (.capturing, .hotkey) where run.hotkeyMode == .hold
            && run.triggeredAt.duration(to: recordingClock.now) < Self.minimumHold:
            cancelRequested()
        case (.capturing, _):
            metrics.begin(.releaseToRecorderStopped, runID: run.id)
            metrics.begin(.releaseToTranscript, runID: run.id)
            metrics.begin(.releaseToClipboard, runID: run.id)
            run.releasedAt = recordingClock.now
            run.stopPauseTranscription()
            metrics.recordQuietBeforeRelease(run.lastLoudAt.duration(to: recordingClock.now), runID: run.id)
            if reason == .hotkey, run.lastBufferWasQuiet == false {
                run.recordingPhase = .releaseTail
                scheduleReleaseTailDeadline(for: run)
            } else {
                stopRecording(run)
            }
        case (.releaseTail, .failure):
            stopRecording(run)
        case (.releaseTail, _), (.stopping, _):
            break
        }
    }

    private func scheduleReleaseTailDeadline(for run: PipelineRun) {
        let runID = run.id
        let clock = recordingClock
        let deadline = clock.now + ReleaseTail.deadline
        run.releaseTailDeadline = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }

            self?.receiveReleaseTail(.deadlineReached, runID: runID)
        }
    }

    private func receiveBufferLevel(dBFS: Double, runID: UUID) {
        guard let run = activeRun, run.id == runID else { return }
        run.lastBufferWasQuiet = ReleaseTail.decision(after: .bufferLevel(dBFS: dBFS)) == .finish
        let now = recordingClock.now
        if let last = run.lastLevelAt, run.lastBufferWasQuiet == false {
            run.voicedDuration += last.duration(to: now)
        }
        run.lastLevelAt = now
        if run.recordingPhase == .capturing {
            if run.lastBufferWasQuiet {
                if run.quietSince == nil { run.quietSince = now }
                schedulePauseTransformation(for: run)
            } else {
                run.lastLoudAt = now
                run.quietSince = nil
                run.pauseCheckedQuiet = false
                run.pauseCheckTask?.cancel()
                run.pauseCheckTask = nil
            }
        }
        receiveReleaseTail(.bufferLevel(dBFS: dBFS), runID: runID)
    }

    private func schedulePauseTransformation(for run: PipelineRun) {
        guard run.pauseTransformationEligible, run.recordingPhase == .capturing,
              run.failure == nil, run.pauseCheckTask == nil, !run.pauseCheckedQuiet,
              let capture = run.pauseAudio, capture.isCapturing,
              let quietSince = run.quietSince else { return }
        let clock = recordingClock
        let transcriber = transcriber
        run.pauseCheckTask = Task { [weak self, weak run] in
            do {
                try await clock.sleep(until: quietSince + PauseTransformation.quietDuration)
                try Task.checkCancellation()
                guard let self, let run else { return }
                guard self.isCurrentRun(run.id), run.recordingPhase == .capturing,
                      run.failure == nil, let audio = capture.snapshot() else {
                    run.pauseCheckTask = nil
                    return
                }
                run.pauseCheckedQuiet = true
                let transcript = try await transcriber.transcribe(audio, request: TranscriptionRequest(
                    locale: Locale(identifier: run.configuration.dictationLocaleID),
                    vocabulary: run.configuration.speechVocabulary,
                    preferFastResults: run.preferFastTranscription
                ))
                try Task.checkCancellation()
                guard self.isCurrentRun(run.id), run.recordingPhase == .capturing,
                      run.failure == nil, capture.isCapturing else { return }
                run.pauseCheckTask = nil
                let input = PauseTransformation.input(transcript, corrections: run.configuration.corrections)
                guard !input.isEmpty, let snapshot = run.providerSnapshot else { return }
                if let previous = run.pauseAttempt, PauseTransformation.sameInput(previous.input, input) { return }
                run.pauseAttempt?.task.cancel()
                run.pauseAttemptCount += 1
                run.pauseAttempt = PauseTransformationAttempt(input: input, instruction: run.transformationInstruction,
                    provider: run.configuration.provider, snapshot: snapshot, clock: clock)
            } catch {
                if !Task.isCancelled { run?.pauseCheckTask = nil }
            }
        }
    }

    private func pauseTransformationOutput(for input: String, run: PipelineRun) async throws -> String? {
        guard run.pauseTransformationEligible else { return nil }
        guard let attempt = run.pauseAttempt else {
            run.pauseOutcome = PauseTransformationOutcome.none
            return nil
        }
        guard PauseTransformation.sameInput(attempt.input, input) else {
            attempt.task.cancel()
            run.pauseOutcome = .miss
            return nil
        }
        let output = await withTaskCancellationHandler {
            await attempt.task.value
        } onCancel: {
            attempt.task.cancel()
        }
        guard isCurrentRun(run.id) else { throw CancellationError() }
        try Task.checkCancellation()
        run.pauseOutcome = output == nil ? .failed : .hit
        if let output { metrics.recordDuration(.translation, duration: output.duration, runID: run.id) }
        return output?.text
    }

    private func receiveReleaseTail(_ event: ReleaseTail.Event, runID: UUID) {
        guard let run = activeRun, run.id == runID, run.recordingPhase == .releaseTail,
              ReleaseTail.decision(after: event) == .finish else { return }

        stopRecording(run)
    }

    private func stopRecording(_ run: PipelineRun) {
        run.recordingPhase = .stopping
        run.releaseTailDeadline?.cancel()
        run.resumeStopWaiter()
    }

    private func scheduleRecordingDurationLimit(for runID: UUID) {
        activeRun?.recordingDurationTask?.cancel()

        let duration = maximumRecordingDurationNanoseconds ?? settings.maximumRecordingDurationNanoseconds
        guard duration > 0 else { return }

        let sleeper = recordingDurationSleeper
        activeRun?.recordingDurationTask = Task { [weak self] in
            do {
                try await sleeper(duration)
            } catch {
                return
            }

            self?.stopRecordingIfDurationExceeded(runID: runID)
        }
    }

    private func stopRecordingIfDurationExceeded(runID: UUID) {
        guard activeRunID == runID, pipelineState == .recording,
              activeRun?.recordingPhase == .capturing else { return }

        requestStopRecording(.durationLimit)
        let duration = maximumRecordingDurationNanoseconds ?? settings.maximumRecordingDurationNanoseconds
        feedback.notifyRecordingAutoStopped(afterSeconds: Int(duration / 1_000_000_000))
    }

    private func resumeStopWaiter() {
        let continuation = activeRun?.stopWaiter
        activeRun?.stopWaiter = nil
        continuation?.resume()
    }

    // MARK: - Run bookkeeping

    private func scheduleErrorReset(for runID: UUID) {
        errorResetTask?.cancel()
        errorResetRunID = runID
        let delay = errorResetDelayNanoseconds
        let sleeper = errorResetSleeper
        errorResetTask = Task { [weak self] in
            do {
                try await sleeper(delay)
            } catch {
                return
            }

            self?.clearErrorIfNeeded(runID: runID)
        }
    }

    private func clearErrorIfNeeded(runID: UUID) {
        guard activeRunID == nil, errorResetRunID == runID else { return }

        if case .error = pipelineState {
            pipelineState = .idle
        }

        errorResetRunID = nil
        errorResetTask = nil
    }

    private func finishRun(_ runID: UUID, keepErrorReset: Bool = false) {
        guard activeRunID == runID else { return }

        clearRunTracking()
        if keepErrorReset == false {
            cancelErrorReset()
        }
    }

    private func clearRunTracking() {
        pendingPasteID = nil
        guard let run = activeRun else { return }
        run.cancelPauseTransformation()
        run.preparedTransformer?.cancel()
        if run.pauseTransformationEligible {
            metrics.recordPauseTransformation(run.pauseOutcome ?? (run.pauseAttempt == nil ? .none : .miss),
                attemptCount: run.pauseAttemptCount, runID: run.id)
        }
        run.streamingTypist?.cancel()
        run.recordingDurationTask?.cancel()
        run.releaseTailDeadline?.cancel()
        run.resumeStopWaiter()
        run.endActivity()
        if run.lowersOtherAudio {
            changeOutputVolume { try await $0.restore() }
        }
        activeRun = nil
        foregroundActivityChanged?(false)
        metrics.discard(runID: run.id)
    }

    func restoreOutputVolumeAfterCrash() {
        changeOutputVolume { try await $0.restoreAfterCrash() }
    }

    private func changeOutputVolume(_ change: @escaping @Sendable (OutputDucker) async throws -> Void) {
        guard let outputDucker else { return }
        let previous = outputVolumeWork
        outputVolumeWork = Task {
            await previous?.value
            do {
                try await change(outputDucker)
            } catch {
                let code = (error as? OutputVolumeError).map { String(describing: $0) } ?? "unknown"
                Self.outputVolumeLogger.error("output_volume_failed error=\(code, privacy: .public)")
            }
        }
    }

    private func cancelActiveStreamingTypist() {
        let typist = activeRun?.streamingTypist
        activeRun?.streamingTypist = nil
        typist?.cancel()
    }

    private func cancelStreamingTypist(ifOwnedBy typist: any StreamingTyping) {
        guard isActiveStreamingTypist(typist) else { return }

        activeRun?.streamingTypist = nil
        typist.cancel()
    }

    private func clearStreamingTypistOwnership(ifOwnedBy typist: any StreamingTyping) {
        guard isActiveStreamingTypist(typist) else { return }
        activeRun?.streamingTypist = nil
    }

    private func isActiveStreamingTypist(_ typist: any StreamingTyping) -> Bool {
        guard let activeStreamingTypist = activeRun?.streamingTypist else { return false }
        return ObjectIdentifier(activeStreamingTypist) == ObjectIdentifier(typist)
    }

    private func isCurrentRun(_ runID: UUID) -> Bool {
        activeRunID == runID
    }

    private func cancelErrorReset() {
        errorResetTask?.cancel()
        errorResetTask = nil
        errorResetRunID = nil
    }

    private func showSuccessFeedback() {
        if settings.playSounds {
            feedback.playSuccessSound(settings.successSound)
        }

        feedbackFlashTask?.cancel()
        isShowingSuccessFeedback = true
        let duration = feedbackFlashDurationNanoseconds
        let sleeper = feedbackFlashSleeper
        feedbackFlashTask = Task { [weak self] in
            do {
                try await sleeper(duration)
            } catch {
                return
            }

            self?.clearSuccessFeedback()
        }
    }

    private func clearSuccessFeedback() {
        isShowingSuccessFeedback = false
        feedbackFlashTask = nil
    }

    private func cancelSuccessFeedback() {
        feedbackFlashTask?.cancel()
        feedbackFlashTask = nil
        isShowingSuccessFeedback = false
    }

    /// Shows an error. When the active run appended a failed history record, the notification offers
    /// that record's transcript and retry actions; it never matches an older record by its message.
    private func presentError(_ error: Error) {
        cancelSuccessFeedback()
        let message = userMessage(for: error)
        pipelineState = .error(message)
        if let recordID = activeRun?.failedRecordID,
           let record = history.records.first(where: { $0.id == recordID }) {
            feedback.notifyTransformationFailed(
                message: message,
                recordID: record.id,
                allowsTranscriptFallback: record.canUseTranscriptFallback,
                allowsRetry: record.canRetryWithOriginalProvider
            )
        } else {
            feedback.notifyError(message: message)
        }
    }

    private func speechModelSelection(for configuration: RunConfiguration) -> (transcriber: (any Transcriber)?, fallbackNotice: String?) {
        guard let installed = speechModels[configuration.speechEngine] else { return (nil, nil) }
        guard let notice = installed.models.state.fallbackNotice(modelName: configuration.speechEngine.displayName) else {
            return (installed.transcriber, nil)
        }
        installed.models.loadIfDownloaded()
        return (nil, notice)
    }

    private func prepareBoundSpeechModels() {
        let bound = settings.workflowList.workflows
            .filter { (HotkeyController.hasShortcut(forWorkflow: $0.id) || settings.workflowList.appRouting.values.contains($0.id)) && $0.input == .voice }
            + [settings.activeWorkflow]
        for engine in Set(bound.filter { $0.input == .voice }.map(\.speechEngine)) {
            speechModels[engine]?.models.loadIfDownloaded()
        }
        let required = Set(bound.map {
            TranscriberAssetManager.bcp47Identifier(for: Locale(identifier: $0.dictationLocaleID))
        })
        guard required != preparedHotkeyLocaleIDs else { return }
        preparedHotkeyLocaleIDs = required
        transcriberAssetManager.prepareLocales(Array(required))
    }
}

extension AppState: AppFeedbackActionHandling {}
