import Foundation
import Observation

/// What `StatusIndicator` reads from the pipeline it shows. `AppState` is the one source.
@MainActor
protocol StatusIndicatorSource: AnyObject {
    var pipelineState: PipelineState { get }
    /// The cue's caption while recording: the revision note, or the name of a workflow other than the active one.
    var recordingCueCaption: String? { get }
    /// An error's delay has passed. Returns the pipeline to idle and returns true, unless a run owns
    /// the pipeline, in which case it changes nothing and returns false.
    func clearErrorAfterDelay() -> Bool
}

/// What the menu bar icon and the floating recording cue show beyond the pipeline state itself: the
/// short success flash after a result, with its sound, and the timed clear of an error. `AppState`
/// owns the pipeline state and calls `syncRecordingCue()` on every change to it; this type owns the
/// two timers and re-applies the cue whenever the flash changes.
@MainActor
@Observable
final class StatusIndicator {
    /// True for the short flash after a result lands. Every assignment re-applies the cue.
    private(set) var isShowingSuccess = false {
        didSet {
            syncRecordingCue()
        }
    }

    @ObservationIgnored weak var source: (any StatusIndicatorSource)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let feedback: any AppFeedbackProviding
    @ObservationIgnored private let recordingCue: (any RecordingCuePresenting)?
    @ObservationIgnored private let flashDurationNanoseconds: UInt64
    @ObservationIgnored private let flashSleeper: FeedbackFlashSleeper
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private let errorResetDelayNanoseconds: UInt64
    @ObservationIgnored private let errorResetSleeper: ErrorResetSleeper
    @ObservationIgnored private var errorResetTask: Task<Void, Never>?
    /// The run, or the copy action, whose error the pending reset clears.
    @ObservationIgnored private var errorResetRunID: UUID?

    init(
        settings: AppSettings,
        feedback: any AppFeedbackProviding,
        recordingCue: (any RecordingCuePresenting)?,
        flashDurationNanoseconds: UInt64,
        flashSleeper: @escaping FeedbackFlashSleeper,
        errorResetDelayNanoseconds: UInt64,
        errorResetSleeper: @escaping ErrorResetSleeper
    ) {
        self.settings = settings
        self.feedback = feedback
        self.recordingCue = recordingCue
        self.flashDurationNanoseconds = flashDurationNanoseconds
        self.flashSleeper = flashSleeper
        self.errorResetDelayNanoseconds = errorResetDelayNanoseconds
        self.errorResetSleeper = errorResetSleeper
    }

    // MARK: - Menu bar icon

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

    static func isMenuBarSymbolAnimated(for state: PipelineState) -> Bool {
        switch state {
        case .recording, .transcribing, .translating:
            true
        case .idle, .error:
            false
        }
    }

    // MARK: - Recording cue

    func syncRecordingCue() {
        guard let recordingCue, let source else { return }
        guard settings.showRecordingCue else {
            recordingCue.apply(.hidden)
            return
        }

        let state: RecordingCueState = switch source.pipelineState {
        case .recording:
            .recording(caption: source.recordingCueCaption)
        case .transcribing, .translating:
            .processing
        case .error(let message):
            .error(message)
        case .idle:
            isShowingSuccess ? .success : .hidden
        }
        recordingCue.apply(state)
    }

    // MARK: - Success flash

    func showSuccess() {
        if settings.playSounds {
            feedback.playSuccessSound(settings.successSound)
        }

        flashTask?.cancel()
        isShowingSuccess = true
        let duration = flashDurationNanoseconds
        let sleeper = flashSleeper
        flashTask = Task { [weak self] in
            do {
                try await sleeper(duration)
            } catch {
                return
            }

            self?.clearSuccess()
        }
    }

    func cancelSuccess() {
        flashTask?.cancel()
        flashTask = nil
        isShowingSuccess = false
    }

    private func clearSuccess() {
        isShowingSuccess = false
        flashTask = nil
    }

    // MARK: - Error reset

    /// Clears the error now on screen after the delay, unless a newer error or a run replaces it first.
    func scheduleErrorReset(for runID: UUID) {
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

            self?.errorResetElapsed(runID: runID)
        }
    }

    func cancelErrorReset() {
        errorResetTask?.cancel()
        errorResetTask = nil
        errorResetRunID = nil
    }

    private func errorResetElapsed(runID: UUID) {
        guard errorResetRunID == runID, source?.clearErrorAfterDelay() == true else { return }

        errorResetRunID = nil
        errorResetTask = nil
    }
}
