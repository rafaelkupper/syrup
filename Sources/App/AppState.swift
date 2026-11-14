import AppKit
import Foundation
import Observation

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

    static let minimumHold: Duration = .milliseconds(300)

    /// A finished result whose clipboard write failed, kept so Copy Result can deliver it later.
    /// `output` is the exact result that history keeps; `delivered` is the sentence-fitted text.
    struct PendingClipboardResult {
        let output: String
        let delivered: String
        let transcript: String
        let transformation: DictationRecord.TransformationSnapshot
        let provider: TranslationProvider
    }

    /// A finished transformation on its way out. History keeps `output`, so Copy Last and revisions
    /// see the exact result; the clipboard and editor receive `fitted.text`.
    struct CompletedOutput {
        let output: String
        let fitted: FittedText
        let transcript: String
        let configuration: RunConfiguration
    }

    private var pendingPasteID: UUID?
    var pendingClipboardResult: PendingClipboardResult?

    private(set) var pipelineState: PipelineState = .idle {
        willSet {
            if newValue != .recording { isFnRecordingLatched = false }
        }
        didSet {
            hotkeyController?.setCancelShortcutEnabled(pipelineState.allowsCancelShortcut)
            syncRecordingCue()
        }
    }
    enum ProcessingPhase { case transcribing, translating }

    /// The run phase files move a run on through this; only this file sets other states.
    func enterProcessing(_ phase: ProcessingPhase) {
        pipelineState = switch phase {
        case .transcribing: .transcribing
        case .translating: .translating
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

    @ObservationIgnored let audioRecorder: any AudioRecording
    @ObservationIgnored let transcriber: any Transcriber
    @ObservationIgnored let speechModels: [SpeechEngine: InstalledSpeechModel]
    let usageStats: UsageStatsStore
    @ObservationIgnored let transformerProvider: any TransformerSnapshotting
    @ObservationIgnored let pasteboard: any PasteboardWriting
    @ObservationIgnored let feedback: any AppFeedbackProviding
    @ObservationIgnored let metrics: any PipelineMetricsRecording
    @ObservationIgnored let delivery: DeliveryCoordinator
    @ObservationIgnored private var preparedHotkeyLocaleIDs: Set<String> = []
    @ObservationIgnored let captureDeliveryTarget: @MainActor (pid_t?) async -> DeliveryTarget?
    @ObservationIgnored let frontmostApplication: @MainActor (Bool) -> (bundleID: String?, processID: pid_t?)
    @ObservationIgnored let selectionReader: any SelectionReading
    @ObservationIgnored private let errorResetDelayNanoseconds: UInt64
    @ObservationIgnored private let errorResetSleeper: ErrorResetSleeper
    @ObservationIgnored private let feedbackFlashDurationNanoseconds: UInt64
    @ObservationIgnored private let feedbackFlashSleeper: FeedbackFlashSleeper
    @ObservationIgnored let maximumRecordingDurationNanoseconds: UInt64?
    @ObservationIgnored let recordingDurationSleeper: RecordingDurationSleeper
    @ObservationIgnored let recordingClock: any RecordingClock
    @ObservationIgnored let processActivity: any ProcessActivityControlling
    @ObservationIgnored let outputVolume: OutputVolumeChain
    /// Run tasks that have not returned yet, keyed by run ID. See `launch`.
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored let streamingTypistFactory: () -> any StreamingTyping
    @ObservationIgnored var activeRun: PipelineRun?
    @ObservationIgnored var foregroundActivityChanged: ((Bool) -> Void)?
    var activeRunID: UUID? { activeRun?.id }
    private var isRevisionRun: Bool { activeRun?.configuration.purpose.isRevision == true }
    @ObservationIgnored private var errorResetTask: Task<Void, Never>?
    @ObservationIgnored private var errorResetRunID: UUID?
    @ObservationIgnored private var feedbackFlashTask: Task<Void, Never>?
    @ObservationIgnored private var hotkeyController: HotkeyController?
    @ObservationIgnored let recordingCue: (any RecordingCuePresenting)?
    @ObservationIgnored private var didNotifyEmptySelectionContext = false
    @ObservationIgnored var didNotifySpeechEngineFallback = false
    @ObservationIgnored private var didNotifyUntrustedSelectionContext = false
    @ObservationIgnored private var didRequestSelectionAccessibilityTrust = false

    /// Every service is injected. Production wiring lives in `AppState.production` at the entry point,
    /// so a test cannot reach the real clipboard, paste, notifications, or microphone by omission.
    init(
        settings: AppSettings,
        transcriberAssetManager: TranscriberAssetManager,
        history: HistoryStore,
        keychainStore: KeychainStore,
        audioRecorder: any AudioRecording,
        transcriber: any Transcriber,
        speechModels: [SpeechEngine: InstalledSpeechModel],
        usageStats: UsageStatsStore,
        transformerProvider: any TransformerSnapshotting,
        pasteboard: any PasteboardWriting,
        feedback: any AppFeedbackProviding,
        metrics: any PipelineMetricsRecording,
        autoPaster: any AutoPasting,
        streamingTypistFactory: @escaping () -> any StreamingTyping,
        selectionReader: any SelectionReading,
        processActivity: any ProcessActivityControlling,
        recordingCue: (any RecordingCuePresenting)?,
        outputDucker: OutputDucker?,
        frontmostApplication: @escaping @MainActor (Bool) -> (bundleID: String?, processID: pid_t?),
        captureDeliveryTarget: @escaping @MainActor (pid_t?) async -> DeliveryTarget?,
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
        installHotkeys: Bool = false
    ) {
        self.settings = settings
        self.transcriberAssetManager = transcriberAssetManager
        self.history = history
        self.keychainStore = keychainStore
        self.audioRecorder = audioRecorder
        self.transcriber = transcriber
        self.speechModels = speechModels
        self.usageStats = usageStats
        self.transformerProvider = transformerProvider
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
        settings.privacyOptIns.attach(history: history)
        self.outputVolume = OutputVolumeChain(ducker: outputDucker)

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
        await settings.refreshActiveDictationLocale { [transcriberAssetManager] localeID in
            await transcriberAssetManager.refreshSupportedLocales(selecting: localeID)
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

    func command(for event: PipelineEvent) -> PipelineCommand {
        PipelineTransitions.command(
            for: event, in: pipelineState,
            run: activeRun?.traits, hasLastResult: lastResult != nil
        )
    }

    func perform(_ command: PipelineCommand, stopReason: RunStopReason = .hotkey) {
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

    /// Revises the newest successful result, like Copy Last: a failed retry of an older revision keeps
    /// that older base in history, and it must not become what the next revision works on.
    func startRevision() {
        guard pipelineState.acceptsNewRun, let baseOutput = lastSuccessfulResult else { return }
        startRevisionRun(configuration: RunConfigurationBuilder.revision(
            of: settings.runConfiguration(workflowID: nil), base: baseOutput
        ))
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
        if activeRun != nil || pipelineState != .idle {
            cancelActiveRun()
        }
        // Runs still unwinding get a bounded wait so quitting never hangs.
        let pending = Array(runTasks.values) + [outputVolume.pending].compactMap { $0 }
        if pending.isEmpty == false {
            _ = try? await withOperationTimeout(.seconds(2), error: CancellationError()) {
                for task in pending { await task.value }
            }
        }
        // A stuck disk write must not hold the quit either; whatever is unwritten is lost, as in a crash.
        _ = try? await withOperationTimeout(.seconds(2), error: CancellationError()) { [usageStats, history] in
            await usageStats.flush()
            await history.flush()
        }
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

    /// Pastes the last result where automatic paste would. Accessibility serves only opt-in automatic
    /// paste, so with automatic paste off this copies the result, like Copy Last.
    func pasteLastResult() async {
        guard settings.autoPasteEnabled else {
            copyLastResult()
            return
        }
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
            // The copy succeeded, so an error still on screen no longer applies, as with Copy Last.
            cancelErrorReset()
            if case .error = pipelineState { pipelineState = .idle }
            // Whenever it copied without pasting, the copied flash shows, every time: the notice for
            // missing Accessibility appears only once per launch.
            if pinsTarget, target == nil {
                delivery.notifyNoCapturedTarget()
                showSuccessFeedback()
                return
            }
            let pasted = try await delivery.pasteCompletedText(delivered, contextTarget: usesSpacing ? target : nil,
                                                               usesSpacing: usesSpacing, knownContext: context, canContinue: { [weak self] in
                self?.pendingPasteID == pasteID && self?.canCopyLastResult == true
            }, targetIsCurrent: {
                guard pinsTarget else { return true }
                return await target?.isCurrent() == true
            })
            if pasted == false { showSuccessFeedback() }
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

    func startRun(workflowID: UUID? = nil) {
        let foreground = frontmostApplication(workflowID == nil && settings.workflowList.appRouting.isEmpty == false)
        let resolvedID = workflowID ?? settings.workflowList.routedWorkflowID(for: foreground.bundleID)
        let workflow = resolvedID.flatMap { id in
            settings.workflowList.workflows.first { $0.id == id }
        } ?? settings.activeWorkflow

        let inputs = settings.runInputs(for: workflow)
        let initialConfiguration = RunConfigurationBuilder.configuration(for: inputs)
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
            inputs: inputs, foregroundPID: foreground.processID,
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
            launch(run) { state in
                await state.runPipeline(runID: runID, resolvedConfiguration: resolved)
            }
        case .selection:
            launch(run) { state in
                guard let configuration = await state.resolveRunContext(run, context) else { return }
                await state.runSelectionPipeline(runID: runID, configuration: configuration)
            }
        }
    }

    private struct RunContextRequest {
        /// Read at the trigger with the rest of the run's settings, not after the selection read.
        let inputs: RunInputs
        let foregroundPID: pid_t?
        let prepareAfterSelection: Bool
    }

    /// Reads the selection a workflow asked for and the editor to deliver into, then builds the run's
    /// final configuration. Returns nil when the run ended or could not start.
    private func resolveRunContext(_ run: PipelineRun, _ request: RunContextRequest) async -> RunConfiguration? {
        let runID = run.id
        let workflow = request.inputs.workflow
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

        let configuration = RunConfigurationBuilder.configuration(for: request.inputs, contextText: contextText)
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
        launch(run) { state in
            await state.runPipeline(runID: runID, resolvedConfiguration: resolved)
        }
    }

    /// Starts a run's task and tracks it until it returns, cancelled or not, so quitting and tests can
    /// wait for a run's work to be over rather than guessing.
    private func launch(_ run: PipelineRun, _ body: @escaping @MainActor (AppState) async -> Void) {
        let id = run.id
        let task = Task { [weak self] in
            guard let self else { return }
            await body(self)
            self.runTasks[id] = nil
        }
        run.task = task
        runTasks[id] = task
    }

    /// Waits for every run task and output-volume change started so far, including those of runs
    /// that were cancelled or superseded.
    /// Finishing work can start more (an ending run restores the output volume), so this repeats until
    /// nothing new has appeared.
    func waitForPendingWork() async {
        var finished: Set<Task<Void, Never>> = []
        while true {
            let pending = (Array(runTasks.values) + [outputVolume.pending].compactMap { $0 })
                .filter { finished.contains($0) == false }
            guard pending.isEmpty == false else { return }
            for task in pending {
                await task.value
                finished.insert(task)
            }
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

    func finishRunSucceeded(_ runID: UUID) {
        guard isCurrentRun(runID) else { return }
        pipelineState = .idle
        showSuccessFeedback()
        finishRun(runID)
    }

    /// Cancellation ends quietly; any other error is shown and clears itself after a delay.
    func finishRunFailed(_ runID: UUID, error: any Error) {
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

    // MARK: - Retry

    func retryTranslation(recordID: UUID) {
        guard let record = history.records.first(where: { $0.id == recordID }),
              let provider = record.provider else { return }
        retryTranslation(recordID: recordID, using: provider)
    }

    func retryTranslation(recordID: UUID, using provider: TranslationProvider) {
        guard pipelineState.acceptsNewRun,
              let record = history.records.first(where: { $0.id == recordID }),
              record.canRetry,
              let (configuration, inputText) = RunConfigurationBuilder.retry(
                  transformation: record.transformation, transcript: record.transcript, output: record.output,
                  provider: provider, activeWorkflow: settings.activeWorkflow, glossary: settings.glossaryList,
                  dictation: settings.dictationOptions(input: .voice, provider: provider)
              ) else {
            return
        }

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
        launch(run) { [captureDeliveryTarget] state in
            if run.needsDeliveryTarget {
                run.deliveryTarget = await captureDeliveryTarget(foregroundPID)
            }
            await state.retryPipeline(
                record: record,
                inputText: inputText,
                configuration: configuration,
                runID: runID
            )
        }
    }

    @discardableResult
    func appendRecord(
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
            outputVolume.restore()
        }
        activeRun = nil
        foregroundActivityChanged?(false)
        metrics.discard(runID: run.id)
    }

    func restoreOutputVolumeAfterCrash() {
        outputVolume.restoreAfterCrash()
    }

    private func cancelActiveStreamingTypist() {
        let typist = activeRun?.streamingTypist
        activeRun?.streamingTypist = nil
        typist?.cancel()
    }

    func cancelStreamingTypist(ifOwnedBy typist: any StreamingTyping) {
        guard isActiveStreamingTypist(typist) else { return }

        activeRun?.streamingTypist = nil
        typist.cancel()
    }

    func clearStreamingTypistOwnership(ifOwnedBy typist: any StreamingTyping) {
        guard isActiveStreamingTypist(typist) else { return }
        activeRun?.streamingTypist = nil
    }

    private func isActiveStreamingTypist(_ typist: any StreamingTyping) -> Bool {
        guard let activeStreamingTypist = activeRun?.streamingTypist else { return false }
        return ObjectIdentifier(activeStreamingTypist) == ObjectIdentifier(typist)
    }

    func isCurrentRun(_ runID: UUID) -> Bool {
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
