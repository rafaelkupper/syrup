import Foundation

enum RunStopReason: Equatable, Sendable {
    case hotkey
    case menu
    case durationLimit
    case failure
}

@MainActor
protocol ProcessActivityControlling {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol
    func endActivity(_ activity: any NSObjectProtocol)
}

extension ProcessInfo: ProcessActivityControlling {}

/// All mutable work owned by one trigger. Superseded runs clean up their own
/// resources; they never acquire ownership of the next run's state.
@MainActor
final class PipelineRun {
    enum RecordingPhase: Equatable {
        case capturing
        case releaseTail
        case stopping
    }

    let id = UUID()
    let triggerWorkflowID: UUID?
    let triggeredAt: ContinuousClock.Instant
    let configuration: RunConfiguration
    let hotkeyMode: HotkeyMode
    let autoPasteEnabled: Bool
    let streamingDeliveryEnabled: Bool
    let showRecordingCue: Bool
    let showLiveTranscript: Bool
    let transformsOnPause: Bool
    let pauseTransformationEligible: Bool
    let providerSnapshot: TransformerSnapshot?
    let speechModel: (transcriber: (any Transcriber)?, fallbackNotice: String?)
    var pauseCheckTask: Task<Void, Never>?
    var pauseAttempt: PauseTransformationAttempt?
    var pauseAttemptCount = 0
    var pauseOutcome: PauseTransformationOutcome?
    let pauseAudio: PauseAudioCapture?
    var pauseCheckedQuiet = false
    var quietSince: ContinuousClock.Instant?
    var lastLoudAt: ContinuousClock.Instant
    var transformationInstruction: String
    let preferFastTranscription: Bool
    let glossaryBlock: String?
    let smartSpacingEnabled: Bool
    let matchesSentenceAtCaret: Bool
    let protectedTerms: [String]
    let pinsDeliveryTarget: Bool
    let lowersOtherAudio: Bool
    var deliveryTarget: DeliveryTarget?
    var task: Task<Void, Never>?
    var recordingDurationTask: Task<Void, Never>?
    var stopWaiter: CheckedContinuation<Void, Never>?
    var recordingPhase = RecordingPhase.capturing
    var lastBufferWasQuiet = false
    var releasedAt: ContinuousClock.Instant?
    var lastLevelAt: ContinuousClock.Instant?
    /// Time between audio buffers that were louder than the quiet level.
    var voicedDuration: Duration = .zero
    var releaseTailDeadline: Task<Void, Never>?
    var failure: (any Error)?
    /// The failed history record this run appended, so its notification offers that record's actions.
    var failedRecordID: UUID?
    var deliveryCommitted = false
    var streamingTypist: (any StreamingTyping)?
    var preparedTransformer: Task<any TextTransformer, Never>?
    private let activities: any ProcessActivityControlling
    private var activity: (any NSObjectProtocol)?

    init(
        configuration: RunConfiguration,
        triggerWorkflowID: UUID?,
        triggeredAt: ContinuousClock.Instant,
        settings: AppSettings,
        holdsPaste: Bool = false,
        activities: any ProcessActivityControlling,
        isVoiceInput: Bool = true,
        providerSnapshot: TransformerSnapshot? = nil,
        speechModel: (transcriber: (any Transcriber)?, fallbackNotice: String?) = (nil, nil)
    ) {
        self.configuration = configuration
        self.triggerWorkflowID = triggerWorkflowID
        self.triggeredAt = triggeredAt
        hotkeyMode = settings.hotkeyMode
        autoPasteEnabled = settings.autoPasteEnabled && holdsPaste == false
        streamingDeliveryEnabled = settings.streamingDeliveryEnabled
        showRecordingCue = settings.showRecordingCue
        showLiveTranscript = settings.showLiveTranscript
        preferFastTranscription = settings.preferFastTranscription
        transformsOnPause = settings.transformsOnPause
        self.providerSnapshot = providerSnapshot
        self.speechModel = speechModel
        pauseTransformationEligible = transformsOnPause && isVoiceInput
            && configuration.purpose == .dictation && speechModel.transcriber == nil
            && configuration.provider != .codexCLI && providerSnapshot?.permitsUnfinalizedInput == true
        pauseAudio = pauseTransformationEligible ? PauseAudioCapture() : nil
        lastLoudAt = triggeredAt
        transformationInstruction = configuration.instruction
        smartSpacingEnabled = settings.smartSpacingEnabled && settings.autoPasteEnabled && holdsPaste == false
        // The fit shapes the clipboard too, so it does not need automatic paste. Onboarding's Taste page
        // holds paste while Syrup itself is frontmost, and there is no editor to fit.
        matchesSentenceAtCaret = settings.matchesSentenceAtCaret && holdsPaste == false
        protectedTerms = settings.glossaryList.terms.map(\.term)
        pinsDeliveryTarget = settings.pinDeliveryTarget
        lowersOtherAudio = settings.lowerOtherAudioWhileRecording
        if case .transcribeOnly = configuration.purpose {
            glossaryBlock = nil
        } else {
            glossaryBlock = PromptBuilder.glossaryBlock(for: settings.glossaryList)
        }
        self.activities = activities
        activity = activities.beginActivity(options: .userInitiated, reason: "Syrup is processing a request")
    }

    /// Smart spacing, caret fit, and pinning all need the editor captured at the trigger.
    var needsDeliveryTarget: Bool {
        autoPasteEnabled && (pinsDeliveryTarget || smartSpacingEnabled || matchesSentenceAtCaret)
    }

    var traits: ActiveRunTraits {
        ActiveRunTraits(
            isRevision: configuration.purpose.isRevision, hotkeyMode: hotkeyMode,
            triggerWorkflowID: triggerWorkflowID, deliveryCommitted: deliveryCommitted
        )
    }

    func endActivity() {
        guard let activity else { return }
        activities.endActivity(activity)
        self.activity = nil
    }

    func resumeStopWaiter() {
        let waiter = stopWaiter
        stopWaiter = nil
        waiter?.resume()
    }

    func stopPauseTranscription() {
        pauseCheckTask?.cancel()
        pauseCheckTask = nil
        pauseAudio?.stop()
    }

    func cancelPauseTransformation() {
        stopPauseTranscription()
        pauseAttempt?.task.cancel()
    }

    func cancel() {
        cancelPauseTransformation()
        task?.cancel()
        preparedTransformer?.cancel()
        recordingDurationTask?.cancel()
        releaseTailDeadline?.cancel()
        streamingTypist?.cancel()
        resumeStopWaiter()
    }
}
