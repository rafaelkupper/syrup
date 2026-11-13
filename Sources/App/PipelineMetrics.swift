import Foundation
import OSLog

enum PipelineMetricStage: String, CaseIterable, Sendable {
    case hotkeyToRecordingStarted
    case selectionCapture = "selection_capture"
    case releaseToRecorderStopped
    case releaseToTranscript
    case releaseToClipboard
    case transcriptionWindow
    case translationConfiguration
    case translation
    case clipboardWrite
    case autoPaste
    case firstVisibleOutput
    case streamingFirstDelta

    var signpostName: StaticString {
        switch self {
        case .hotkeyToRecordingStarted:
            "hotkey_to_recording_started"
        case .selectionCapture:
            "selection_capture"
        case .releaseToRecorderStopped:
            "release_to_recorder_stopped"
        case .releaseToTranscript:
            "release_to_transcript"
        case .releaseToClipboard:
            "release_to_clipboard"
        case .transcriptionWindow:
            "transcription_window"
        case .translationConfiguration:
            "translation_configuration"
        case .translation:
            "translation"
        case .clipboardWrite:
            "clipboard_write"
        case .autoPaste:
            "auto_paste"
        case .firstVisibleOutput:
            "first_visible_output"
        case .streamingFirstDelta:
            "streaming_first_delta"
        }
    }
}

enum PipelineDeliveryMode: String, Equatable, Sendable {
    case atomic
    case streamed
    case streamedPartial = "streamed_partial"
}

enum PauseTransformationOutcome: String, Equatable, Sendable {
    case hit, miss, none, failed
}

@MainActor
protocol PipelineMetricsRecording: AnyObject {
    func begin(_ stage: PipelineMetricStage, runID: UUID)
    func end(_ stage: PipelineMetricStage, runID: UUID)
    func recordDeliveryMode(_ mode: PipelineDeliveryMode, runID: UUID)
    func recordDuration(_ stage: PipelineMetricStage, duration: Duration, runID: UUID)
    func recordQuietBeforeRelease(_ duration: Duration, runID: UUID)
    func recordPauseTransformation(_ outcome: PauseTransformationOutcome, attemptCount: Int, runID: UUID)
    func discard(runID: UUID)
}

@MainActor
final class PipelineMetricsRecorder: PipelineMetricsRecording {
    private struct ActiveInterval {
        let state: OSSignpostIntervalState
        let startedAt: ContinuousClock.Instant
    }

    private struct IntervalKey: Hashable {
        let runID: UUID
        let stage: PipelineMetricStage
    }

    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "PipelineMetrics")
    private let signposter = OSSignposter(subsystem: "org.syrup.SyrupApp", category: "PipelineMetrics")
    private var activeIntervals: [IntervalKey: ActiveInterval] = [:]

    func begin(_ stage: PipelineMetricStage, runID: UUID) {
        let key = IntervalKey(runID: runID, stage: stage)
        let state = signposter.beginInterval(stage.signpostName, id: signposter.makeSignpostID())
        activeIntervals[key] = ActiveInterval(state: state, startedAt: clock.now)
    }

    func end(_ stage: PipelineMetricStage, runID: UUID) {
        let key = IntervalKey(runID: runID, stage: stage)
        guard let interval = activeIntervals.removeValue(forKey: key) else { return }

        let duration = interval.startedAt.duration(to: clock.now)
        signposter.endInterval(stage.signpostName, interval.state)
        recordDuration(stage, duration: duration, runID: runID)
    }

    func recordDuration(_ stage: PipelineMetricStage, duration: Duration, runID: UUID) {
        logger.info(
            "pipeline_stage=\(stage.rawValue, privacy: .public) run_id=\(runID.uuidString, privacy: .public) duration_ms=\(duration.millisecondsDescription, privacy: .public)"
        )
    }

    func recordQuietBeforeRelease(_ duration: Duration, runID: UUID) {
        logger.info("quiet_before_release_ms=\(duration.millisecondsDescription, privacy: .public) run_id=\(runID.uuidString, privacy: .public)")
    }

    func recordPauseTransformation(_ outcome: PauseTransformationOutcome, attemptCount: Int, runID: UUID) {
        logger.info("pause_transformation=\(outcome.rawValue, privacy: .public) attempt_count=\(attemptCount, privacy: .public) run_id=\(runID.uuidString, privacy: .public)")
    }

    func discard(runID: UUID) {
        activeIntervals = activeIntervals.filter { key, interval in
            guard key.runID == runID else { return true }

            signposter.endInterval(key.stage.signpostName, interval.state)
            return false
        }
    }

    func recordDeliveryMode(_ mode: PipelineDeliveryMode, runID: UUID) {
        logger.info(
            "pipeline_delivery_mode=\(mode.rawValue, privacy: .public) run_id=\(runID.uuidString, privacy: .public)"
        )
    }
}
