import AppKit
import Foundation
import Observation

typealias ErrorResetSleeper = @Sendable (UInt64) async throws -> Void
typealias FeedbackFlashSleeper = @Sendable (UInt64) async throws -> Void
typealias RecordingDurationSleeper = @Sendable (UInt64) async throws -> Void
typealias AutoPasteSleeper = @Sendable (UInt64) async throws -> Void

/// Owns the pipeline state and the active run, and orchestrates each run: which events start or stop
/// it (`PipelineTransitions`), recording and transcription, transformation, and committing the result.
/// Each other concern has its own owner, which `AppState` composes and calls:
/// - `StatusIndicator`: the menu bar icon, the recording cue, the success flash, and the error reset.
/// - `ResultActions`: Copy and Paste Last, and the result kept after a failed clipboard write.
/// - `DeliveryCoordinator`: how committed text reaches the editor.
/// - `SpeechReadiness`: speech locales and models for the workflows a person can start.
/// - `OutputVolumeChain`: lowering and restoring other audio while recording.
@MainActor
@Observable
final class AppState {
    typealias PipelineState = Syrup.PipelineState

    static let minimumHold: Duration = .milliseconds(300)

    /// A finished transformation on its way out. History keeps `output`, so Copy Last and revisions
    /// see the exact result; the clipboard and editor receive `fitted.text`.
    struct CompletedOutput {
        let output: String
        let fitted: FittedText
        let transcript: String
        let configuration: RunConfiguration
    }

    // MARK: - Pipeline state

    private(set) var pipelineState: PipelineState = .idle {
        willSet {
            if newValue != .recording { isFnRecordingLatched = false }
        }
        didSet {
            hotkeyController?.pipelineStateChanged()
            status.syncRecordingCue()
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

    // MARK: - Hotkeys

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
    @ObservationIgnored private var hotkeyController: HotkeyController?

    // MARK: - Owners

    @ObservationIgnored let status: StatusIndicator
    @ObservationIgnored let results: ResultActions
    @ObservationIgnored let delivery: DeliveryCoordinator
    @ObservationIgnored let speech: SpeechReadiness
    @ObservationIgnored let outputVolume: OutputVolumeChain

    // MARK: - Services

    let settings: AppSettings
    let transcriberAssetManager: TranscriberAssetManager
    let history: HistoryStore
    let autoPaster: any AutoPasting
    let usageStats: UsageStatsStore
    @ObservationIgnored let keychainStore: KeychainStore
    @ObservationIgnored let audioRecorder: any AudioRecording
    @ObservationIgnored let transcriber: any Transcriber
    @ObservationIgnored let transformerProvider: any TransformerSnapshotting
    @ObservationIgnored let pasteboard: any PasteboardWriting
    @ObservationIgnored let feedback: any AppFeedbackProviding
    @ObservationIgnored let metrics: any PipelineMetricsRecording
    @ObservationIgnored let captureDeliveryTarget: @MainActor (pid_t?) async -> DeliveryTarget?
    @ObservationIgnored let frontmostApplication: @MainActor (Bool) -> (bundleID: String?, processID: pid_t?)
    @ObservationIgnored let selectionReader: any SelectionReading
    @ObservationIgnored let maximumRecordingDurationNanoseconds: UInt64?
    @ObservationIgnored let recordingDurationSleeper: RecordingDurationSleeper
    @ObservationIgnored let recordingClock: any RecordingClock
    @ObservationIgnored let processActivity: any ProcessActivityControlling
    @ObservationIgnored let streamingTypistFactory: () -> any StreamingTyping
    @ObservationIgnored let recordingCue: (any RecordingCuePresenting)?

    // MARK: - Run tracking

    @ObservationIgnored var activeRun: PipelineRun?
    var activeRunID: UUID? { activeRun?.id }
    private var isRevisionRun: Bool { activeRun?.configuration.purpose.isRevision == true }
    /// Run tasks that have not returned yet, keyed by run ID. See `launch`.
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var foregroundActivityChanged: ((Bool) -> Void)?
    /// Once-per-launch notices from the selection read at a run's start (`resolveRunContext`).
    @ObservationIgnored private var didNotifyEmptySelectionContext = false
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
        self.speech = SpeechReadiness(settings: settings, assetManager: transcriberAssetManager, models: speechModels)
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
        let delivery = DeliveryCoordinator(
            autoPaster: autoPaster,
            feedback: feedback,
            metrics: metrics,
            streamingTypistFactory: streamingTypistFactory,
            autoPasteDelayNanoseconds: autoPasteDelayNanoseconds,
            autoPasteSleeper: autoPasteSleeper,
            captureDeliveryTarget: captureDeliveryTarget,
            frontmostApplication: frontmostApplication
        )
        let status = StatusIndicator(
            settings: settings,
            feedback: feedback,
            recordingCue: recordingCue,
            flashDurationNanoseconds: feedbackFlashDurationNanoseconds,
            flashSleeper: feedbackFlashSleeper,
            errorResetDelayNanoseconds: errorResetDelayNanoseconds,
            errorResetSleeper: errorResetSleeper
        )
        self.delivery = delivery
        self.status = status
        self.results = ResultActions(
            history: history,
            settings: settings,
            pasteboard: pasteboard,
            autoPaster: autoPaster,
            delivery: delivery,
            status: status,
            captureDeliveryTarget: captureDeliveryTarget,
            frontmostApplication: frontmostApplication
        )
        self.maximumRecordingDurationNanoseconds = maximumRecordingDurationNanoseconds
        self.recordingDurationSleeper = recordingDurationSleeper
        self.recordingClock = recordingClock
        self.processActivity = processActivity
        self.recordingCue = recordingCue
        settings.privacyOptIns.attach(history: history)
        self.outputVolume = OutputVolumeChain(ducker: outputDucker)

        status.source = self
        results.host = self
        if let appFeedback = feedback as? AppFeedback {
            appFeedback.actionHandler = self
        }

        if installHotkeys {
            self.installHotkeys()
        }
    }

    func installHotkeys(registration: any HotkeyRegistering = SystemHotkeyRegistration()) {
        guard hotkeyController == nil else { return }
        install(HotkeyController(appState: self, registration: registration))
    }

    /// Installs a controller built elsewhere, so a test can supply its Fn monitor.
    func install(_ controller: HotkeyController) {
        guard hotkeyController == nil else { return }
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
        speech.prepareBoundWorkflows()
    }

    func refreshDictationLocales() async {
        await speech.refreshDictationLocales()
    }

    var isMenuBarSymbolAnimated: Bool {
        StatusIndicator.isMenuBarSymbolAnimated(for: pipelineState)
    }

    var recordingCueCaption: String? {
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
        Self.menuBarSymbol(for: pipelineState, showingSuccess: status.isShowingSuccess)
    }

    static func menuBarSymbol(for state: PipelineState, showingSuccess: Bool) -> String {
        StatusIndicator.menuBarSymbol(for: state, showingSuccess: showingSuccess)
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
        guard pipelineState.acceptsNewRun, let baseOutput = results.lastSuccessfulResult else { return }
        startRevisionRun(configuration: RunConfigurationBuilder.revision(
            of: settings.runConfiguration(workflowID: nil), base: baseOutput
        ))
    }

    private func cancelActiveRun() {
        cancelActiveStreamingTypist()
        activeRun?.cancel()
        status.cancelErrorReset()
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

    var lastResult: String? { results.lastResult }
    var transcriptFallback: String? { results.transcriptFallback }
    var canCopyTranscriptFallback: Bool { results.canCopyTranscriptFallback }
    var canCopyLastResult: Bool { results.canCopyLastResult }
    var canCopyPendingResult: Bool { results.canCopyPendingResult }

    func copyPendingResult() { results.copyPendingResult() }
    func copyTranscriptFallback(recordID: UUID? = nil) { results.copyTranscriptFallback(recordID: recordID) }
    func copyHistoryRecord(recordID: UUID) { results.copyHistoryRecord(recordID: recordID) }
    func copyLastResult() { results.copyLastResult() }
    func pasteLastResult() async { await results.pasteLastResult() }

    func showIdleAfterCopy() {
        pipelineState = .idle
    }

    func clearErrorAfterCopy() {
        if case .error = pipelineState { pipelineState = .idle }
    }

    // MARK: - Starting runs

    private func beginRun(_ run: PipelineRun, state: PipelineState) {
        status.cancelErrorReset()
        status.cancelSuccess()
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
            speechModel: workflow.input == .voice ? speech.modelSelection(for: initialConfiguration) : (nil, nil)
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
            speechModel: speech.modelSelection(for: configuration)
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
        status.showSuccess()
        finishRun(runID)
    }

    /// Cancellation ends quietly; any other error is shown and clears itself after a delay.
    func finishRunFailed(_ runID: UUID, error: any Error) {
        guard isCurrentRun(runID) else { return }
        if error is CancellationError {
            status.cancelSuccess()
            pipelineState = .idle
            finishRun(runID)
        } else {
            presentError(error)
            status.scheduleErrorReset(for: runID)
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
        status.scheduleErrorReset(for: runID)
        finishRun(runID, keepErrorReset: true)
    }

    // MARK: - Run bookkeeping

    func clearErrorAfterDelay() -> Bool {
        guard activeRunID == nil else { return false }

        if case .error = pipelineState {
            pipelineState = .idle
        }
        return true
    }

    private func finishRun(_ runID: UUID, keepErrorReset: Bool = false) {
        guard activeRunID == runID else { return }

        clearRunTracking()
        if keepErrorReset == false {
            status.cancelErrorReset()
        }
    }

    private func clearRunTracking() {
        results.cancelPendingPaste()
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

    /// Shows an error. When the active run appended a failed history record, the notification offers
    /// that record's transcript and retry actions; it never matches an older record by its message.
    func presentError(_ error: Error) {
        status.cancelSuccess()
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
}

extension AppState: AppFeedbackActionHandling {}

extension AppState: StatusIndicatorSource {}

extension AppState: ResultActionsHost {}
