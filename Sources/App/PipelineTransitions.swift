import Foundation

/// The externally visible stage of the pipeline. Only `AppState` changes it.
enum PipelineState: Equatable {
    case idle
    case recording
    case transcribing
    case translating
    case error(String)

    var allowsCancelShortcut: Bool {
        switch self {
        case .recording, .transcribing, .translating:
            true
        case .idle, .error:
            false
        }
    }

    var isError: Bool { if case .error = self { true } else { false } }

    /// No run owns the pipeline, so a new one may start.
    var acceptsNewRun: Bool {
        switch self {
        case .idle, .error: true
        case .recording, .transcribing, .translating: false
        }
    }
}

/// A hotkey, menu, or cancel request.
enum PipelineEvent: Equatable {
    case triggerPressed(workflowID: UUID?)
    case triggerReleased(workflowID: UUID?)
    case revisionPressed
    case revisionReleased
    case revisionMenu
    case cancel
}

/// What `AppState` does in response to a `PipelineEvent`.
enum PipelineCommand: Equatable {
    case ignore
    case startRun(workflowID: UUID?)
    case startRevision
    case stopRecording
    case cancelRun
}

/// The parts of the active run that decide how events apply to it.
struct ActiveRunTraits: Equatable {
    var isRevision: Bool
    var hotkeyMode: HotkeyMode
    var triggerWorkflowID: UUID?
    var deliveryCommitted: Bool
}

/// Every legal transition for trigger, release, revision, and cancel events, in one pure function.
/// `AppState` performs the returned command; the recording-phase details (minimum hold, release
/// tail) stay in `requestStopRecording`, and async completions move the state forward from there.
enum PipelineTransitions {
    static func command(
        for event: PipelineEvent,
        in state: PipelineState,
        run: ActiveRunTraits?,
        hasLastResult: Bool
    ) -> PipelineCommand {
        switch (event, state) {
        case (.triggerPressed(let workflowID), .idle), (.triggerPressed(let workflowID), .error):
            return .startRun(workflowID: workflowID)
        case (.triggerPressed(let workflowID), .recording):
            guard let run, run.isRevision == false, run.hotkeyMode == .toggle,
                  run.triggerWorkflowID == workflowID else { return .ignore }
            return .stopRecording
        case (.triggerPressed, .transcribing), (.triggerPressed, .translating):
            // Once the clipboard and history hold the result, the run finishes its paste and feedback.
            return run?.deliveryCommitted == true ? .ignore : .cancelRun

        case (.triggerReleased(let workflowID), .recording):
            guard let run, run.isRevision == false, run.hotkeyMode == .hold,
                  run.triggerWorkflowID == workflowID else { return .ignore }
            return .stopRecording
        case (.triggerReleased, _):
            return .ignore

        case (.revisionPressed, .idle), (.revisionPressed, .error),
             (.revisionMenu, .idle), (.revisionMenu, .error):
            return hasLastResult ? .startRevision : .ignore
        case (.revisionPressed, .recording):
            guard let run, run.isRevision, run.hotkeyMode == .toggle else { return .ignore }
            return .stopRecording
        case (.revisionMenu, .recording):
            guard let run, run.isRevision else { return .ignore }
            return .stopRecording
        case (.revisionReleased, .recording):
            guard let run, run.isRevision, run.hotkeyMode == .hold else { return .ignore }
            return .stopRecording
        case (.revisionPressed, _), (.revisionReleased, _), (.revisionMenu, _):
            return .ignore

        case (.cancel, .idle):
            return .ignore
        case (.cancel, _):
            return run?.deliveryCommitted == true ? .ignore : .cancelRun
        }
    }
}
