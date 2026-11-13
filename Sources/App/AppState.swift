import AppKit
import AVFoundation
import Foundation
import KeyboardShortcuts
import Observation
import OSLog

enum PipelineError: Error, Equatable {
    case emptyTranscript
    case noSelectedText
    case selectionAccessibilityRequired
    case selectionSourceChanged
    case streamingFailed(String)
}

typealias ErrorResetSleeper = @Sendable (UInt64) async throws -> Void
typealias FeedbackFlashSleeper = @Sendable (UInt64) async throws -> Void
typealias RecordingDurationSleeper = @Sendable (UInt64) async throws -> Void
typealias AutoPasteSleeper = @Sendable (UInt64) async throws -> Void

func userMessage(for error: Error) -> String {
    if let secretError = error as? KeychainStoreError {
        return switch secretError {
        case .readFailed: "The saved API key could not be read. Check access to Syrup's local secret store."
        case .saveFailed: "API key could not be saved"
        case .deleteFailed: "API key could not be removed"
        }
    }
    if let audioError = error as? AudioRecordingError {
        switch audioError {
        case .microphoneAccessDenied:
            return "Microphone access denied - enable Syrup in System Settings > Privacy & Security > Microphone."
        case .builtInMicrophoneUnavailableWithClosedLid: return "The built-in microphone is off while the lid is closed. Connect or select another microphone."
        case .microphoneStartFailed:
            return "Microphone could not start"
        case .audioBufferOverflow:
            return "Audio processing could not keep up. Try a shorter dictation."
        }
    }

    if let pipelineError = error as? PipelineError {
        switch pipelineError {
        case .emptyTranscript:
            return "Nothing heard"
        case .noSelectedText:
            return "No text selected"
        case .selectionAccessibilityRequired:
            return "Accessibility access required - grant Syrup access in System Settings > Privacy & Security > Accessibility."
        case .selectionSourceChanged:
            return "The selected editor changed - select the text and try again."
        case .streamingFailed(let message):
            return "\(message) - partial text may remain in the target app"
        }
    }

    if let transcriptionError = error as? TranscriptionError {
        switch transcriptionError {
        case .speechRecognitionAccessDenied:
            return "Speech recognition access denied - enable Syrup in System Settings > Privacy & Security > Speech Recognition."
        case .speechRecognitionRestricted:
            return "Speech recognition is restricted on this Mac"
        case .speechTranscriberUnavailable:
            return "On-device transcription is not available on this Mac"
        case .localeNotSupported(let languageName):
            return "\(languageName) is not supported for on-device transcription"
        case .languageModelInstalling(let languageName):
            return "\(languageName) language model is downloading - open Settings to see progress."
        case .languageModelUnavailable(let languageName):
            return "\(languageName) language model could not be installed"
        case .noCompatibleAudioFormat:
            return "Speech recognition could not use the microphone audio format"
        case .finalizationTimedOut:
            return "Speech recognition timed out. Please try again."
        case .audioConversionFailed:
            return "Audio could not be prepared for speech recognition"
        }
    }

    if let translationError = error as? TranslationError {
        switch translationError {
        case .missingConfiguration:
            return "Translation endpoint is not configured"
        case .invalidBaseURL:
            return "Translation endpoint URL is invalid"
        case .invalidResponse:
            return "Translation endpoint returned an invalid response"
        case .emptyResponse:
            return "Translation was empty"
        case .outputLimitReached:
            return "The model stopped before finishing - try a shorter input or another model."
        case .responseFiltered:
            return "The model declined part of this content - the result was not delivered."
        case .cannotConnect(let host):
            return "Can't reach \(host)"
        case .timedOut:
            return "Translation timed out"
        case .apiKeyRejected:
            return "API key rejected"
        case .rateLimited:
            return "Rate limited"
        case .httpStatus(let statusCode):
            return "Translation endpoint returned HTTP \(statusCode)"
        case .codexCLINotFound:
            return "Codex CLI not found - install it or set its path in Settings"
        case .codexNotSignedIn:
            return "Codex isn't signed in - run `codex login` in Terminal"
        case .codexUsageLimit:
            return "Codex usage limit reached - try later or switch provider"
        case .codexEmptyOutput:
            return "Codex returned no output"
        case .codexFailed(let exitCode):
            return "Codex failed (exit \(exitCode))"
        case .codexTimedOut:
            return "Codex timed out"
        case .onDeviceUnavailable(let reason):
            return reason
        case .onDeviceGuardrail:
            return "The on-device model declined this content - transcript kept"
        case .onDeviceContextExceeded:
            return "Dictation too long for the on-device model - switch provider or dictate in shorter parts"
        }
    }

    if let clipboardError = error as? ClipboardError {
        switch clipboardError {
        case .writeFailed:
            return "Clipboard could not be written"
        }
    }

    if error is CancellationError {
        return "Canceled"
    }

    return "Something went wrong"
}

@MainActor
@Observable
final class AppState {
    private static let minimumHold: Duration = .milliseconds(300)
    private static let outputVolumeLogger = Logger(subsystem: "org.syrup.SyrupApp", category: "OutputVolume")

    private struct PendingClipboardResult {
        let text: String
        let transcript: String
        let transformation: DictationRecord.TransformationSnapshot
        let provider: TranslationProvider
    }

    private var pendingPasteID: UUID?
    private var pendingClipboardResult: PendingClipboardResult?
    enum PipelineState: Equatable {
        case idle
        case recording
        case transcribing
        case translating
        case error(String)
    }

    var pipelineState: PipelineState = .idle {
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
    @ObservationIgnored private let transformerProvider: any TransformerProviding
    @ObservationIgnored private let pasteboard: any PasteboardWriting
    @ObservationIgnored private let feedback: any AppFeedbackProviding
    @ObservationIgnored private let metrics: any PipelineMetricsRecording
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
    @ObservationIgnored private let autoPasteDelayNanoseconds: UInt64
    @ObservationIgnored private let autoPasteSleeper: AutoPasteSleeper
    @ObservationIgnored private let recordingClock: any RecordingClock
    @ObservationIgnored private let processActivity: any ProcessActivityControlling
    @ObservationIgnored private let outputDucker: OutputDucker?
    @ObservationIgnored private var outputVolumeWork: Task<Void, Never>?
    @ObservationIgnored private let streamingTypistFactory: () -> any StreamingTyping
    @ObservationIgnored private var activeRun: PipelineRun?
    @ObservationIgnored var foregroundActivityChanged: ((Bool) -> Void)?
    private var activeRunID: UUID? { activeRun?.id }
    private var activeTriggerWorkflowID: UUID? { activeRun?.triggerWorkflowID }
    private var activeRunPurpose: RunPurpose? { activeRun?.configuration.purpose }
    @ObservationIgnored private var errorResetTask: Task<Void, Never>?
    @ObservationIgnored private var errorResetRunID: UUID?
    @ObservationIgnored private var feedbackFlashTask: Task<Void, Never>?
    @ObservationIgnored private var hotkeyController: HotkeyController?
    @ObservationIgnored private let recordingCue: (any RecordingCuePresenting)?
    @ObservationIgnored let recordingArchive: (any RecordingArchiving)?
    @ObservationIgnored private var didNotifyAutoPasteNotTrusted = false
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
        transformerProvider: (any TransformerProviding)? = nil,
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
        self.errorResetDelayNanoseconds = errorResetDelayNanoseconds
        self.errorResetSleeper = errorResetSleeper
        self.feedbackFlashDurationNanoseconds = feedbackFlashDurationNanoseconds
        self.feedbackFlashSleeper = feedbackFlashSleeper
        self.maximumRecordingDurationNanoseconds = maximumRecordingDurationNanoseconds
        self.recordingDurationSleeper = recordingDurationSleeper
        self.autoPasteDelayNanoseconds = autoPasteDelayNanoseconds
        self.autoPasteSleeper = autoPasteSleeper
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
        if activeRunPurpose == .revision {
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
        if pipelineState == .idle, isShowingSuccessFeedback {
            return "checkmark.circle"
        }

        return switch pipelineState {
        case .idle:
            "waveform"
        case .recording:
            "waveform.badge.microphone"
        case .transcribing, .translating:
            "ellipsis"
        case .error:
            "exclamationmark.triangle"
        }
    }

    func triggerPressed(workflowID: UUID? = nil) {
        guard isHotkeyPaused == false else { return }

        switch pipelineState {
        case .idle, .error:
            startRun(workflowID: workflowID)
        case .recording:
            if activeRunPurpose != .revision,
               (activeRun?.hotkeyMode ?? settings.hotkeyMode) == .toggle,
               activeTriggerWorkflowID == workflowID {
                requestStopRecording(.hotkey)
            }
        case .transcribing, .translating:
            cancelRequested()
        }
    }

    func triggerReleased(workflowID: UUID? = nil) {
        guard isHotkeyPaused == false else { return }

        switch pipelineState {
        case .recording:
            if activeRunPurpose != .revision,
               (activeRun?.hotkeyMode ?? settings.hotkeyMode) == .hold,
               activeTriggerWorkflowID == workflowID {
                requestStopRecording(.hotkey)
            }
        case .idle, .transcribing, .translating, .error:
            break
        }
    }

    func startRevision() {
        switch pipelineState {
        case .idle, .error:
            break
        case .recording, .transcribing, .translating:
            return
        }

        guard let baseOutput = lastResult else { return }
        let activeConfiguration = settings.runConfiguration(workflowID: nil)

        let configuration = RunConfiguration(
            workflowID: activeConfiguration.workflowID,
            workflowName: activeConfiguration.workflowName,
            dictationLocaleID: activeConfiguration.dictationLocaleID,
            instruction: "",
            provider: activeConfiguration.provider,
            transformation: .revision(adjustment: "", instruction: ""),
            purpose: .revision,
            speechVocabulary: activeConfiguration.speechVocabulary,
            speechEngine: activeConfiguration.speechEngine,
            corrections: activeConfiguration.corrections
        )
        startRun(
            configuration: configuration,
            triggerWorkflowID: nil,
            revisionBaseOutput: baseOutput
        )
    }

    var revisionMenuActionTitle: String {
        if pipelineState == .recording, activeRunPurpose == .revision {
            "Finish revision"
        } else {
            "Revise last result"
        }
    }

    var canPerformRevisionMenuAction: Bool {
        switch pipelineState {
        case .idle, .error:
            lastResult != nil
        case .recording:
            activeRunPurpose == .revision
        case .transcribing, .translating:
            false
        }
    }

    func performRevisionMenuAction() {
        guard canPerformRevisionMenuAction else { return }

        if pipelineState == .recording, activeRunPurpose == .revision {
            requestStopRecording(.menu)
        } else {
            startRevision()
        }
    }

    func revisionTriggerPressed() {
        guard isHotkeyPaused == false else { return }

        switch pipelineState {
        case .idle, .error:
            startRevision()
        case .recording:
            if activeRunPurpose == .revision, (activeRun?.hotkeyMode ?? settings.hotkeyMode) == .toggle {
                requestStopRecording(.hotkey)
            }
        case .transcribing, .translating:
            break
        }
    }

    func revisionTriggerReleased() {
        guard isHotkeyPaused == false,
              pipelineState == .recording,
              activeRunPurpose == .revision,
              (activeRun?.hotkeyMode ?? settings.hotkeyMode) == .hold else {
            return
        }

        requestStopRecording(.hotkey)
    }

    func cancelRequested() {
        guard pipelineState != .idle else { return }
        if activeRun?.deliveryCommitted == true {
            return
        }

        cancelActiveStreamingTypist()
        activeRun?.cancel()
        cancelErrorReset()
        audioRecorder.stop()
        resumeStopWaiter()
        clearRunTracking()
        pipelineState = .idle
    }

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
        guard transcriptFallback != nil else { return false }

        switch pipelineState {
        case .idle, .error:
            return true
        case .recording, .transcribing, .translating:
            return false
        }
    }

    var canCopyLastResult: Bool {
        guard lastSuccessfulResult != nil else { return false }

        switch pipelineState {
        case .idle, .error:
            return true
        case .recording, .transcribing, .translating:
            return false
        }
    }

    var canCopyPendingResult: Bool {
        pendingClipboardResult != nil && (pipelineState == .idle || pipelineState.isError)
    }

    func copyPendingResult() {
        guard canCopyPendingResult, let result = pendingClipboardResult else { return }
        do {
            try pasteboard.write(result.text)
            appendRecord(
                transcript: result.transcript,
                output: result.text,
                transformation: result.transformation,
                outcome: .success,
                provider: result.provider
            )
            pendingClipboardResult = nil
            cancelErrorReset()
            pipelineState = .idle
            showSuccessFeedback()
        } catch {
            let runID = UUID()
            presentError(error)
            scheduleErrorReset(for: runID)
        }
    }

    func copyTranscriptFallback(recordID: UUID? = nil) {
        guard pipelineState == .idle || pipelineState.isError,
              let record = recordID.flatMap({ id in history.records.first { $0.id == id } }) ?? (recordID == nil ? history.records.first : nil),
              record.canUseTranscriptFallback else {
            return
        }

        do {
            try pasteboard.write(record.transcript)
            appendRecord(
                transcript: record.transcript,
                output: record.transcript,
                transformation: record.transformation,
                outcome: .success,
                provider: record.provider
            )
            cancelErrorReset()
            pipelineState = .idle
            showSuccessFeedback()
        } catch {
            let runID = UUID()
            presentError(error)
            scheduleErrorReset(for: runID)
        }
    }

    func copyHistoryRecord(recordID: UUID) {
        switch pipelineState {
        case .idle, .error:
            break
        case .recording, .transcribing, .translating:
            return
        }

        guard let record = history.records.first(where: { $0.id == recordID }),
              record.canCopyFromHistory else {
            return
        }
        let text = record.output ?? record.transcript

        do {
            try pasteboard.write(text)
            cancelErrorReset()
            pipelineState = .idle
            showSuccessFeedback()
        } catch {
            let runID = UUID()
            presentError(error)
            scheduleErrorReset(for: runID)
        }
    }

    func copyLastResult() {
        guard canCopyLastResult, let text = lastSuccessfulResult else { return }

        do {
            try pasteboard.write(text)
            cancelErrorReset()
            pipelineState = .idle
            showSuccessFeedback()
        } catch {
            let runID = UUID()
            presentError(error)
            scheduleErrorReset(for: runID)
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
            try await pasteCompletedText(delivered, contextTarget: usesSpacing ? target : nil,
                                         usesSpacing: usesSpacing, knownContext: context, canContinue: { [weak self] in
                self?.pendingPasteID == pasteID && self?.canCopyLastResult == true
            }, targetIsCurrent: { !pinsTarget || target?.isCurrent() == true })
        } catch is CancellationError {
        } catch {
            presentError(error)
            scheduleErrorReset(for: UUID())
        }
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
        activeRun = run
        foregroundActivityChanged?(true)
        let runID = run.id
        let foregroundPID = foreground.processID
        let glossary = settings.glossaryList
        let prepareAfterSelection = workflow.includeSelectionContext && run.configuration.provider == .appleOnDevice
        if prepareAfterSelection == false { prepareTransformer(for: run) }
        pipelineState = workflow.input == .voice ? .recording : .translating
        if workflow.input == .voice {
            metrics.begin(.hotkeyToRecordingStarted, runID: runID)
            scheduleRecordingDurationLimit(for: runID)
        }
        run.task = Task { [weak self] in
            guard let self else { return }
            guard isCurrentRun(runID), Task.isCancelled == false else { return }

            var contextText: String?
            if workflow.input == .selection || workflow.includeSelectionContext {
                metrics.begin(.selectionCapture, runID: runID)
                let capture = await selectionReader.captureForRun(processID: foregroundPID)
                guard isCurrentRun(runID), Task.isCancelled == false else { return }
                metrics.end(.selectionCapture, runID: runID)

                if run.autoPasteEnabled, (run.pinsDeliveryTarget || run.smartSpacingEnabled || run.matchesSentenceAtCaret) {
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
                    return
                case (.selection, .notTrusted):
                    if didRequestSelectionAccessibilityTrust == false {
                        didRequestSelectionAccessibilityTrust = true
                        autoPaster.requestTrust()
                    }
                    failRunStart(PipelineError.selectionAccessibilityRequired, runID: runID)
                    return
                case (.voice, .sourceChanged):
                    feedback.notifyError(message: "The selected editor changed - ran without context.")
                case (.selection, .sourceChanged):
                    failRunStart(PipelineError.selectionSourceChanged, runID: runID)
                    return
                }
            }

            if run.autoPasteEnabled, (run.pinsDeliveryTarget || run.smartSpacingEnabled || run.matchesSentenceAtCaret), run.deliveryTarget == nil {
                run.deliveryTarget = await captureDeliveryTarget(foregroundPID)
            }
            guard isCurrentRun(runID), Task.isCancelled == false else { return }

            let base = run.configuration
            let hasContext = workflow.input == .voice && workflow.includeSelectionContext && contextText != nil
            let configuration = RunConfiguration(
                workflowID: base.workflowID, workflowName: base.workflowName,
                dictationLocaleID: base.dictationLocaleID,
                instruction: PromptBuilder.instruction(
                    for: workflow.kind, glossary: glossary, context: hasContext ? contextText : nil,
                    dictation: settings.dictationOptions(input: workflow.input, provider: base.provider)
                ),
                provider: base.provider,
                transformation: workflow.input == .selection || hasContext
                    ? .contextual(workflowName: base.workflowName, instruction: base.instruction) : base.transformation,
                purpose: base.purpose, contextText: contextText, speechVocabulary: base.speechVocabulary,
                speechEngine: base.speechEngine, corrections: base.corrections
            )
            if prepareAfterSelection { prepareTransformer(for: run, instruction: configuration.instruction) }
            switch workflow.input {
            case .voice:
                await runPipeline(runID: runID, configuration: configuration, revisionBaseOutput: nil)
            case .selection:
                await runSelectionPipeline(runID: runID, configuration: configuration)
            }
        }
    }

    private func startRun(
        configuration: RunConfiguration,
        triggerWorkflowID: UUID?,
        revisionBaseOutput: String?
    ) {
        cancelErrorReset()
        cancelSuccessFeedback()
        clearRunTracking()

        let run = PipelineRun(
            configuration: configuration,
            triggerWorkflowID: triggerWorkflowID,
            triggeredAt: recordingClock.now,
            settings: settings,
            holdsPaste: holdsPasteNow,
            activities: processActivity,
            providerSnapshot: configuration.purpose.isTransformation ? transformerProvider.snapshot(for: configuration.provider) : nil,
            speechModel: speechModelSelection(for: configuration)
        )
        activeRun = run
        foregroundActivityChanged?(true)
        let runID = run.id
        pipelineState = .recording
        metrics.begin(.hotkeyToRecordingStarted, runID: runID)
        scheduleRecordingDurationLimit(for: runID)
        let foregroundPID = frontmostApplication(false).processID
        prepareTransformer(for: run)
        run.task = Task { [weak self, captureDeliveryTarget] in
            if run.autoPasteEnabled, (run.pinsDeliveryTarget || run.smartSpacingEnabled || run.matchesSentenceAtCaret) {
                run.deliveryTarget = await captureDeliveryTarget(foregroundPID)
            }
            await self?.runPipeline(
                runID: runID,
                configuration: configuration,
                revisionBaseOutput: revisionBaseOutput
            )
        }
    }

    private func prepareTransformer(for run: PipelineRun, instruction: String? = nil) {
        if case .transcribeOnly = run.configuration.purpose { return }
        metrics.begin(.translationConfiguration, runID: run.id)
        let provider = run.providerSnapshot ?? transformerProvider.snapshot(for: run.configuration.provider)
        run.preparedTransformer = Task { [metrics] in
            let transformer = await provider.transformer(for: run.configuration.provider, instruction: instruction ?? run.configuration.instruction)
            metrics.end(.translationConfiguration, runID: run.id)
            if let failed = transformer as? FailedTextTransformer {
                recordingFailed(failed.error, runID: run.id)
            }
            return transformer
        }
    }

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

            pipelineState = .idle
            showSuccessFeedback()
            finishRun(runID)
        } catch is CancellationError {
            if isCurrentRun(runID) {
                cancelSuccessFeedback()
                pipelineState = .idle
                finishRun(runID)
            }
        } catch {
            if isCurrentRun(runID) {
                presentError(error)
                scheduleErrorReset(for: runID)
                finishRun(runID, keepErrorReset: true)
            }
        }
    }

    private func runPipeline(
        runID: UUID,
        configuration: RunConfiguration,
        revisionBaseOutput: String?
    ) async {
        var transcriptionTask: Task<String, any Error>?
        var appleTranscriptionTask: Task<String, any Error>?
        var transformerTask: Task<any TextTransformer, Never>?
        var provisionalRecordingID: UUID?
        var recordingTeeSession: RecordingTeeSession?
        defer {
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
                    // Archiving is best-effort and must never fail a dictation.
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

            transformerTask = run.preparedTransformer
            try Task.checkCancellation()

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
                    try await transcriber.transcribe(
                        previewAudio, locale: locale, vocabulary: configuration.speechVocabulary,
                        onPartialTranscript: streams ? nil : onPartialTranscript, preferFastResults: true
                    )
                }
                appleTranscriptionTask = preview
                transcriptionTask = Task {
                    let parakeetText: String?
                    do {
                        parakeetText = try await parakeetTranscriber.transcribe(
                            finalAudio, locale: locale, vocabulary: configuration.speechVocabulary,
                            onPartialTranscript: streams ? onPartialTranscript : nil
                        )
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
                        return try await transcriber.transcribe(
                        audio,
                        locale: locale,
                        vocabulary: configuration.speechVocabulary,
                        onPartialTranscript: onPartialTranscript,
                        preferFastResults: run.preferFastTranscription
                    )
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
            case .revision:
                guard let revisionBaseOutput else {
                    preconditionFailure("Revision runs require a captured base output")
                }
                let instruction = PromptBuilder.compose(
                    base: PromptBuilder.revisionInstruction(adjustment: trimmedTranscript),
                    glossary: run.glossaryBlock,
                    context: nil,
                    contract: PromptBuilder.outputContract
                )
                transformationInput = revisionBaseOutput
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
                    purpose: .revision,
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
                Task { [settings] in
                    await tee?.waitForCompletion()
                    let appleTranscript = if let appleTranscription {
                        ((try? await appleTranscription.value) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        rawTranscript
                    }
                    if settings.glossaryLearningEnabled, appleTranscript.isEmpty == false {
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
            pipelineState = .idle
            showSuccessFeedback()
            finishRun(runID)
        } catch is CancellationError {
            if isCurrentRun(runID) {
                audioRecorder.stop()
            }
            await recordingTeeSession?.cancelAndWait()
            if let provisionalRecordingID {
                await recordingArchive?.discardEntry(id: provisionalRecordingID)
            }
            if isCurrentRun(runID) {
                cancelSuccessFeedback()
                pipelineState = .idle
                finishRun(runID)
            }
        } catch {
            if isCurrentRun(runID) {
                audioRecorder.stop()
            }
            await recordingTeeSession?.cancelAndWait()
            if let provisionalRecordingID {
                await recordingArchive?.discardEntry(id: provisionalRecordingID)
            }
            if isCurrentRun(runID) {
                presentError(error)
                scheduleErrorReset(for: runID)
                finishRun(runID, keepErrorReset: true)
            }
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
            transformerTask = Task { [transformerProvider, metrics] in
                let transformer = await transformerProvider.transformer(
                    for: configuration.provider,
                    instruction: configuration.instruction
                )
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

        if let run = activeRun,
           (run.streamingDeliveryEnabled && run.autoPasteEnabled && autoPaster.isTrusted)
                || (run.showRecordingCue && recordingCue != nil),
           let streamingTransformer = transformer as? any StreamingTextTransformer,
           let streamedText = try await streamAndDeliver(
               inputText: inputText,
               transcript: transcript,
               recordTranscript: recordTranscript,
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
            if isCurrentRun(runID), Task.isCancelled == false {
                appendRecord(
                    transcript: recordTranscript ?? transcript,
                    output: configuration.purpose == .revision ? inputText : nil,
                    transformation: configuration.transformation,
                    outcome: .failed(message: userMessage(for: error))
                )
            }
            throw error
        }

        return try await commitAtomicOutput(transformedText, transcript: recordTranscript ?? transcript,
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
        let fit = await sentenceFit(for: transformedText, run: run)
        guard isCurrentRun(runID) else { throw CancellationError() }
        try Task.checkCancellation()

        metrics.begin(.clipboardWrite, runID: runID)
        try writeCompletedResult(
            fit.text,
            transcript: transcript,
            configuration: configuration
        )
        metrics.end(.clipboardWrite, runID: runID)
        if recordReleaseToClipboard {
            metrics.end(.releaseToClipboard, runID: runID)
        }

        appendRecord(
            transcript: transcript,
            output: transformedText,
            transformation: configuration.transformation,
            outcome: .success
        )
        activeRun?.deliveryCommitted = true
        metrics.recordDeliveryMode(.atomic, runID: runID)
        try await autoPasteIfNeeded(text: fit.text, runID: runID, knownContext: fit.context)
        return transformedText
    }

    /// Match the sentence at the cursor. The clipboard and any paste carry the fitted text, and history
    /// keeps the exact result so Copy Last and Paste Last can fit it again elsewhere. The cursor is read
    /// once, just before the clipboard write: at the pinned editor while it is still current, otherwise
    /// in the app in front, where a manual Command-V would land.
    private func sentenceFit(
        for text: String, run: PipelineRun, knownContext: CaretContext? = nil
    ) async -> (text: String, context: CaretContext?) {
        guard run.matchesSentenceAtCaret, autoPaster.isTrusted else { return (text, nil) }
        var context = knownContext
        if context == nil {
            let target: DeliveryTarget?
            if let pinned = run.deliveryTarget, pinned.isCurrent() {
                target = pinned
            } else if let processID = frontmostApplication(false).processID,
                      processID != ProcessInfo.processInfo.processIdentifier {
                target = await captureDeliveryTarget(processID)
            } else {
                target = nil
            }
            context = await target?.caretContext(readsSentence: true)
        }
        guard let context else { return (text, nil) }
        return (SentenceFit.apply(text, context: context, protectedTerms: run.protectedTerms), context)
    }

    private func streamAndDeliver(
        inputText: String,
        transcript: String,
        recordTranscript: String?,
        configuration: RunConfiguration,
        runID: UUID,
        transformer: any StreamingTextTransformer,
        recordReleaseToClipboard: Bool
    ) async throws -> String? {
        guard let run = activeRun, run.id == runID else { throw CancellationError() }
        let typesIntoEditor = run.streamingDeliveryEnabled && run.autoPasteEnabled && autoPaster.isTrusted && deliveryTargetIsCurrent(run)
        let typist: any StreamingTyping = typesIntoEditor ? streamingTypistFactory() : PreviewOnlyTypist()
        typist.setTargetValidator { [weak self, weak run] in
            guard let self, let run else { return false }
            return self.isCurrentRun(runID) && self.deliveryTargetIsCurrent(run)
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
                let deliveryError: any Error = if typist.hasPostedText {
                    PipelineError.streamingFailed(userMessage(for: error))
                } else {
                    error
                }
                if isCurrentRun(runID), Task.isCancelled == false {
                    appendRecord(
                        transcript: recordTranscript ?? transcript,
                        output: configuration.purpose == .revision ? inputText : nil,
                        transformation: configuration.transformation,
                        outcome: .failed(message: userMessage(for: deliveryError))
                    )
                    if typist.hasPostedText {
                        metrics.recordDeliveryMode(.streamedPartial, runID: runID)
                    }
                }
                throw deliveryError
            }
        } catch {
            cancelStreamingTypist(ifOwnedBy: typist)
            let deliveryError: any Error = if typist.hasPostedText {
                PipelineError.streamingFailed(userMessage(for: error))
            } else {
                error
            }
            if isCurrentRun(runID), Task.isCancelled == false {
                appendRecord(
                    transcript: recordTranscript ?? transcript,
                    output: configuration.purpose == .revision ? inputText : nil,
                    transformation: configuration.transformation,
                    outcome: .failed(message: userMessage(for: deliveryError))
                )
                if typist.hasPostedText {
                    metrics.recordDeliveryMode(.streamedPartial, runID: runID)
                }
            }
            throw deliveryError
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
            transformedText = OpenAICompatibleTransformer.normalizedModelOutput(
                fullText,
                keepsWrapperQuotes: keepsWrapperQuotes
            )
        }
        guard transformedText.isEmpty == false else {
            let deliveryError: any Error = if typist.hasPostedText {
                PipelineError.streamingFailed(userMessage(for: TranslationError.emptyResponse))
            } else {
                TranslationError.emptyResponse
            }
            appendRecord(
                transcript: recordTranscript ?? transcript,
                output: configuration.purpose == .revision ? inputText : nil,
                transformation: configuration.transformation,
                outcome: .failed(message: userMessage(for: deliveryError))
            )
            if typist.hasPostedText {
                metrics.recordDeliveryMode(.streamedPartial, runID: runID)
            }
            throw deliveryError
        }

        // The typist fitted what it typed with the context it read; reuse it so the clipboard matches.
        let fit: (text: String, context: CaretContext?)
        if readTypedContext {
            fit = (typedContext.map {
                SentenceFit.apply(transformedText, context: $0, protectedTerms: run.protectedTerms)
            } ?? transformedText, typedContext)
        } else {
            fit = await sentenceFit(for: transformedText, run: run)
            guard isCurrentRun(runID) else { throw CancellationError() }
            try Task.checkCancellation()
        }

        metrics.begin(.clipboardWrite, runID: runID)
        try writeCompletedResult(
            fit.text,
            transcript: recordTranscript ?? transcript,
            configuration: configuration
        )
        metrics.end(.clipboardWrite, runID: runID)
        if recordReleaseToClipboard {
            metrics.end(.releaseToClipboard, runID: runID)
        }

        appendRecord(
            transcript: recordTranscript ?? transcript,
            output: transformedText,
            transformation: configuration.transformation,
            outcome: .success
        )
        activeRun?.deliveryCommitted = true

        if typist.hasPostedText == false, (atomicFallbackText != nil || typesIntoEditor == false) {
            try await autoPasteIfNeeded(text: fit.text, runID: runID, knownContext: fit.context)
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
            switch stopReason {
            case .focusChanged:
                feedback.notifyStreamingFocusChanged()
            case .secureInputActive:
                feedback.notifyStreamingSecureInput()
            case .eventCreationFailed:
                feedback.notifyError(message: "Typing stopped - the full result was copied.")
            }
        } else {
            metrics.recordDeliveryMode(typesIntoEditor ? .streamed : .atomic, runID: runID)
        }
        return transformedText
    }

    func retryTranslation(recordID: UUID) {
        guard let record = history.records.first(where: { $0.id == recordID }),
              let provider = record.provider else { return }
        retryTranslation(recordID: recordID, using: provider)
    }

    func retryTranslation(recordID: UUID, using provider: TranslationProvider) {
        switch pipelineState {
        case .idle, .error:
            break
        case .recording, .transcribing, .translating:
            return
        }

        guard let record = history.records.first(where: { $0.id == recordID }),
              record.canRetry else {
            return
        }

        let inputText: String
        switch record.transformation {
        case .revision:
            guard let baseOutput = record.output else { return }
            inputText = baseOutput
        case .translation, .custom, .contextual:
            inputText = record.transcript
        }

        cancelErrorReset()
        cancelSuccessFeedback()
        clearRunTracking()

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
        let purpose: RunPurpose
        if case .revision = record.transformation {
            purpose = .revision
        } else {
            purpose = .dictation
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
        activeRun = run
        foregroundActivityChanged?(true)
        let runID = run.id
        pipelineState = .translating

        prepareTransformer(for: run)
        let foregroundPID = frontmostApplication(false).processID
        run.task = Task { [weak self, captureDeliveryTarget] in
            if run.autoPasteEnabled, (run.pinsDeliveryTarget || run.smartSpacingEnabled || run.matchesSentenceAtCaret) {
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
            pipelineState = .idle
            showSuccessFeedback()
            finishRun(runID)
        } catch is CancellationError {
            if isCurrentRun(runID) {
                cancelSuccessFeedback()
                pipelineState = .idle
                finishRun(runID)
            }
        } catch {
            if isCurrentRun(runID) {
                presentError(error)
                scheduleErrorReset(for: runID)
                finishRun(runID, keepErrorReset: true)
            }
        }
    }

    func setPersistHistory(_ isEnabled: Bool) async {
        if await history.setPersistenceEnabled(isEnabled) { settings.persistHistory = isEnabled }
    }

    private func deliveryTargetIsCurrent(_ run: PipelineRun) -> Bool {
        run.pinsDeliveryTarget == false || run.deliveryTarget?.isCurrent() == true
    }

    private func autoPasteIfNeeded(text: String, runID: UUID, knownContext: CaretContext? = nil) async throws {
        guard let run = activeRun, run.id == runID, run.autoPasteEnabled else { return }
        guard deliveryTargetIsCurrent(run) else {
            feedback.notifyError(message: "The editor changed - the full result was copied.")
            return
        }

        metrics.begin(.autoPaste, runID: runID)
        defer {
            metrics.end(.autoPaste, runID: runID)
        }

        try await pasteCompletedText(text, contextTarget: run.smartSpacingEnabled ? run.deliveryTarget : nil,
                                     usesSpacing: run.smartSpacingEnabled, knownContext: knownContext,
                                     canContinue: { [weak self] in self?.isCurrentRun(runID) == true },
                                     targetIsCurrent: { [weak self, weak run] in
                                         guard let self, let run else { return false }
                                         return self.deliveryTargetIsCurrent(run)
                                     })
    }

    /// Pastes text that is already on the clipboard, already fitted when caret fit is on. Smart spacing
    /// reuses a cursor context read for the fit, or reads its one unit here.
    private func pasteCompletedText(_ text: String, contextTarget: DeliveryTarget?,
                                    usesSpacing: Bool, knownContext: CaretContext?,
                                    canContinue: @escaping @MainActor () -> Bool,
                                    targetIsCurrent: @escaping @MainActor () -> Bool) async throws {
        try await autoPasteSleeper(autoPasteDelayNanoseconds)
        guard canContinue(), Task.isCancelled == false else { throw CancellationError() }
        guard targetIsCurrent() else {
            feedback.notifyError(message: "The editor changed - the full result was copied.")
            return
        }
        let spaces = usesSpacing && text.first?.isWhitespace == false
        var context = knownContext
        if spaces, context == nil, let contextTarget, autoPaster.isTrusted {
            context = await contextTarget.caretContext(readsSentence: false)
            guard canContinue(), !Task.isCancelled else { throw CancellationError() }
            guard targetIsCurrent() else {
                feedback.notifyError(message: "The editor changed - the full result was copied.")
                return
            }
        }
        let prefix = spaces && context?.precedingWordCharacter == true ? " " : ""
        do {
            let strategy = autoPaster.strategy
            if strategy == .typeText || !prefix.isEmpty {
                let typist = streamingTypistFactory()
                typist.setTargetValidator { canContinue() && targetIsCurrent() }
                try typist.typeText(strategy == .typeText ? prefix + text : prefix)
                switch typist.stopReason {
                case .focusChanged:
                    feedback.notifyError(message: "The editor changed - the full result was copied.")
                case .secureInputActive:
                    feedback.notifyAutoPasteSecureInput()
                case .eventCreationFailed:
                    feedback.notifyError(message: "Typing stopped - the full result was copied.")
                case nil:
                    break
                }
                if typist.stopReason != nil { return }
            }
            if case .commandV(let keyCode) = strategy { try autoPaster.paste(keyCode: keyCode) }
        } catch AutoPasteError.notTrusted {
            if didNotifyAutoPasteNotTrusted == false {
                didNotifyAutoPasteNotTrusted = true
                feedback.notifyAutoPasteNotTrusted()
            }
        } catch AutoPasteError.secureInputActive {
            feedback.notifyAutoPasteSecureInput()
        } catch {
            feedback.notifyError(message: "Typing stopped - the full result was copied.")
        }
    }

    private func appendRecord(
        transcript: String,
        output: String?,
        transformation: DictationRecord.TransformationSnapshot,
        outcome: DictationRecord.Outcome,
        provider: TranslationProvider? = nil
    ) {
        history.append(DictationRecord(
            id: UUID(),
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
    }

    private func writeCompletedResult(
        _ text: String,
        transcript: String,
        configuration: RunConfiguration
    ) throws {
        if let failure = activeRun?.failure { throw failure }
        do {
            try pasteboard.write(text)
            pendingClipboardResult = nil
        } catch {
            pendingClipboardResult = PendingClipboardResult(
                text: text,
                transcript: transcript,
                transformation: configuration.transformation,
                provider: configuration.provider
            )
            throw error
        }
    }

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
                let transcript = try await transcriber.transcribe(audio,
                    locale: Locale(identifier: run.configuration.dictationLocaleID),
                    vocabulary: run.configuration.speechVocabulary, onPartialTranscript: nil,
                    preferFastResults: run.preferFastTranscription)
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

    private func presentError(_ error: Error) {
        cancelSuccessFeedback()
        let message = userMessage(for: error)
        pipelineState = .error(message)
        if let record = history.records.first,
           case .failed(let failedMessage) = record.outcome,
           failedMessage == message {
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
            .filter { ($0.hasRegisteredHotkey || settings.workflowList.appRouting.values.contains($0.id)) && $0.input == .voice }
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

private extension Workflow {
    var hasRegisteredHotkey: Bool {
        KeyboardShortcuts.getShortcut(for: .dictateWorkflow(id)) != nil
    }
}

extension AppState.PipelineState {
    var allowsCancelShortcut: Bool {
        switch self {
        case .recording, .transcribing, .translating:
            true
        case .idle, .error:
            false
        }
    }
}

extension AppState: AppFeedbackActionHandling {}

extension AppState.PipelineState {
    var isError: Bool { if case .error = self { true } else { false } }
}
