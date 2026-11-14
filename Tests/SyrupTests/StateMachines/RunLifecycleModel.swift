import Foundation
@testable import Syrup

/// A finite model of a voice run's lifecycle as `AppState` drives it: shortcuts and menu items, the
/// minimum hold, the release tail, the duration limit, microphone and transcription failures, the
/// provider, the single commit point, automatic paste, the success flash, the error reset, Copy last,
/// Copy result again, pausing shortcuts, and the late completions of runs that were cancelled.
///
/// Each action is one thing that happens from outside: a key, a menu item, a buffer level, a timer, or
/// an async completion. After it, the model runs the run task until it waits again, as the main actor
/// does, so every model state is a settled state that a test can reach and observe in the real
/// `AppState`. Event dispatch goes through the real `PipelineTransitions.command` and release-tail
/// decisions through the real `ReleaseTail.decision`, so those are never restated here.
///
/// Left out: selected-text and retry runs, which share the transformation and commit modeled here
/// but never record; Paste Last; streamed delivery; early transformation; and the learning archive.
struct RunLifecycleModel: StateMachineModel {
    let hotkeyMode: HotkeyMode
    let autoPaste: Bool
    /// Cancelled runs whose provider or transcriber has not returned yet. Starting a run is refused
    /// beyond this, which keeps the model finite.
    static let staleLimit = 2
    static let failure = PipelineState.error("failed")

    enum Trigger: String, Hashable, CaseIterable { case dictate, workflow }

    enum Purpose: Hashable {
        case dictation(Trigger)
        case revision

        var isRevision: Bool { self == .revision }
        var triggerWorkflow: Trigger? {
            if case .dictation(let trigger) = self, trigger == .workflow { return .workflow }
            return nil
        }
    }

    /// Where the run task waits.
    enum Position: Hashable {
        case starting
        case waitingForStop
        case waitingForTranscript
        case waitingForTransform
        case waitingForPaste
    }

    enum Transcript: String, Hashable { case text, empty, failure }

    enum Transform: Hashable {
        case output(clipboardWorks: Bool)
        case failure
    }

    struct Run: Hashable {
        var purpose: Purpose
        var position = Position.starting
        var phase = PipelineRun.RecordingPhase.capturing
        var heldLong = false
        var lastBufferQuiet = false
        var failed = false
        var committed = false
        var transcriptPending = false
        var transformPending = false
        var durationTimerPending = true
        /// A result handed to the run task that it has not acted on yet. Only a key pressed in the
        /// same instant, before the main actor runs the task, sees this.
        var transcriptResult: Transcript?
        var transformResult: Transform?
    }

    struct State: Hashable, CustomStringConvertible {
        var pipeline = PipelineState.idle
        var run: Run?
        /// History holds a result for Copy last and revision.
        var hasResult: Bool
        /// A result the clipboard refused, kept for Copy result again.
        var hasPendingResult = false
        var paused = false
        var flash = false
        var errorReset = false
        var staleTranscripts = 0
        var staleTransforms = 0

        var escapeAvailable: Bool { paused == false && pipeline.allowsCancelShortcut }

        var description: String {
            var parts = ["\(pipeline)"]
            if let run {
                parts.append("run(\(run.purpose), \(run.position), \(run.phase)"
                    + (run.heldLong ? ", held" : "") + (run.lastBufferQuiet ? ", quiet" : "")
                    + (run.failed ? ", failed" : "") + (run.committed ? ", committed" : "") + ")")
            }
            if hasResult { parts.append("result") }
            if hasPendingResult { parts.append("pending result") }
            if paused { parts.append("paused") }
            if flash { parts.append("flash") }
            if errorReset { parts.append("reset pending") }
            if staleTranscripts > 0 { parts.append("\(staleTranscripts) stale transcript(s)") }
            if staleTransforms > 0 { parts.append("\(staleTransforms) stale transform(s)") }
            return parts.joined(separator: ", ")
        }
    }

    enum Racer: String, Hashable { case escape, press }

    enum Action: Hashable, CustomStringConvertible {
        case press(Trigger)
        case release(Trigger)
        case revisionPress
        case revisionRelease
        case revisionMenu
        case escape
        case pause
        case resume
        case copyLast(clipboardWorks: Bool)
        case copyResultAgain(clipboardWorks: Bool)
        case holdPasses
        case buffer(quiet: Bool)
        case tailDeadline
        case durationLimit
        case microphoneFails
        case transcript(Transcript)
        case transform(Transform)
        case pasteDelayEnds
        case flashEnds
        case errorResetFires
        case staleTranscript
        case staleTransform
        /// A transcript or provider output arrives, and a key lands before the run task sees it.
        case racedTranscript(then: Racer)
        case racedTransform(then: Racer)

        /// Something the person does, as opposed to time passing or work finishing.
        var isUserInput: Bool {
            switch self {
            case .press, .release, .revisionPress, .revisionRelease, .revisionMenu, .escape, .pause, .resume,
                 .copyLast, .copyResultAgain, .racedTranscript, .racedTransform:
                true
            default:
                false
            }
        }

        var description: String {
            switch self {
            case .press(let trigger): "press \(trigger.rawValue)"
            case .release(let trigger): "release \(trigger.rawValue)"
            case .revisionPress: "press revise"
            case .revisionRelease: "release revise"
            case .revisionMenu: "menu revise"
            case .escape: "Esc"
            case .pause: "pause shortcuts"
            case .resume: "resume shortcuts"
            case .copyLast(let works): "Copy last" + (works ? "" : " (clipboard refuses)")
            case .copyResultAgain(let works): "Copy result again" + (works ? "" : " (clipboard refuses)")
            case .holdPasses: "300 ms pass"
            case .buffer(let quiet): quiet ? "quiet buffer" : "loud buffer"
            case .tailDeadline: "tail deadline"
            case .durationLimit: "duration limit"
            case .microphoneFails: "microphone fails"
            case .transcript(let result): "transcript \(result.rawValue)"
            case .transform(.output(let works)): "provider output" + (works ? "" : " (clipboard refuses)")
            case .transform(.failure): "provider fails"
            case .pasteDelayEnds: "paste delay ends"
            case .flashEnds: "flash ends"
            case .errorResetFires: "error reset fires"
            case .staleTranscript: "cancelled run's transcript returns"
            case .staleTransform: "cancelled run's provider returns"
            case .racedTranscript(let racer): "transcript text, then \(racer.rawValue) at once"
            case .racedTransform(let racer): "provider output, then \(racer.rawValue) at once"
            }
        }
    }

    /// What a transition does outside the state: the clipboard, history, paste, and notices.
    struct Effects: Equatable {
        var clipboardWrites = 0
        var successRecords = 0
        var failedRecords = 0
        var pastes = 0
        var errorsShown = 0
        var autoStopNotices = 0
        var flashesStarted = 0
    }

    static let allActions: [Action] = {
        var actions: [Action] = [.revisionPress, .revisionRelease, .revisionMenu, .escape, .pause, .resume,
            .holdPasses, .tailDeadline, .durationLimit, .microphoneFails, .pasteDelayEnds, .flashEnds,
            .errorResetFires, .staleTranscript, .staleTransform,
            .transform(.failure), .transform(.output(clipboardWorks: true)), .transform(.output(clipboardWorks: false))]
        for trigger in Trigger.allCases { actions += [.press(trigger), .release(trigger)] }
        for works in [true, false] { actions += [.copyLast(clipboardWorks: works), .copyResultAgain(clipboardWorks: works)] }
        for quiet in [true, false] { actions.append(.buffer(quiet: quiet)) }
        for result in [Transcript.text, .empty, .failure] { actions.append(.transcript(result)) }
        for racer in [Racer.escape, .press] { actions += [.racedTranscript(then: racer), .racedTransform(then: racer)] }
        return actions
    }()

    var initialStates: [State] {
        [State(hasResult: false), State(hasResult: true)]
    }

    func successors(of state: State) -> [(action: Action, next: State)] {
        Self.allActions.compactMap { action in step(state, action).map { (action, $0.next) } }
    }

    /// The settled state after `action`, and its effects, or nil when the action cannot happen.
    func step(_ state: State, _ action: Action) -> (next: State, effects: Effects)? {
        var transition = Transition(model: self, state: state)
        guard transition.apply(action), transition.refusedStart == false else { return nil }
        transition.settle()
        return (transition.state, transition.effects)
    }
}

/// One action applied to a copy of the state, following `AppState` call by call.
private struct Transition {
    let model: RunLifecycleModel
    var state: RunLifecycleModel.State
    var effects = RunLifecycleModel.Effects()

    typealias Action = RunLifecycleModel.Action

    /// Applies the synchronous part of an action. Returns false when it cannot happen in this state.
    mutating func apply(_ action: Action) -> Bool {
        switch action {
        case .press(let trigger):
            shortcut(.triggerPressed(workflowID: id(trigger)))
        case .release(let trigger):
            shortcut(.triggerReleased(workflowID: id(trigger)))
        case .revisionPress:
            shortcut(.revisionPressed)
        case .revisionRelease:
            shortcut(.revisionReleased)
        case .revisionMenu:
            // The menu is not a shortcut, so pausing shortcuts leaves it working.
            perform(command(for: .revisionMenu), reason: .menu)
        case .escape:
            guard state.escapeAvailable else { return false }
            cancelRequested()
        case .pause:
            guard state.paused == false else { return false }
            state.paused = true
            cancelRequested()
        case .resume:
            guard state.paused else { return false }
            state.paused = false
        case .copyLast(let works):
            guard state.hasResult, state.pipeline.acceptsNewRun else { return false }
            copy(clipboardWorks: works, keepsResult: false)
        case .copyResultAgain(let works):
            guard state.hasPendingResult, state.pipeline.acceptsNewRun else { return false }
            copy(clipboardWorks: works, keepsResult: true)
        case .holdPasses:
            guard let run = state.run, state.pipeline == .recording, run.phase == .capturing, run.heldLong == false
            else { return false }
            state.run?.heldLong = true
        case .buffer(let quiet):
            guard let run = state.run, state.pipeline == .recording, run.position != .starting, run.phase != .stopping
            else { return false }
            receiveBufferLevel(quiet: quiet)
        case .tailDeadline:
            guard state.run?.phase == .releaseTail else { return false }
            receiveReleaseTail(.deadlineReached)
        case .durationLimit:
            guard state.run?.durationTimerPending == true else { return false }
            state.run?.durationTimerPending = false
            if state.pipeline == .recording, state.run?.phase == .capturing {
                requestStopRecording(.durationLimit)
                effects.autoStopNotices += 1
            }
        case .microphoneFails:
            guard state.run != nil, state.pipeline == .recording else { return false }
            recordingFailed()
        case .transcript(let result):
            guard let run = state.run, run.transcriptPending,
                  result == .failure || run.position == .waitingForTranscript else { return false }
            state.run?.transcriptPending = false
            if result == .failure {
                // The transcription task's own catch runs first.
                recordingFailed()
            }
            state.run?.transcriptResult = result
        case .transform(let result):
            guard state.run?.transformPending == true else { return false }
            state.run?.transformPending = false
            state.run?.transformResult = result
        case .pasteDelayEnds:
            guard state.run?.position == .waitingForPaste else { return false }
            effects.pastes += 1
            succeed()
        case .flashEnds:
            guard state.flash else { return false }
            state.flash = false
        case .errorResetFires:
            guard state.errorReset else { return false }
            state.errorReset = false
            if state.run == nil, state.pipeline.isError {
                state.pipeline = .idle
            }
        case .staleTranscript:
            guard state.staleTranscripts > 0 else { return false }
            state.staleTranscripts -= 1
        case .staleTransform:
            guard state.staleTransforms > 0 else { return false }
            state.staleTransforms -= 1
        case .racedTranscript(let racer):
            guard let run = state.run, run.transcriptPending, run.position == .waitingForTranscript else { return false }
            state.run?.transcriptPending = false
            state.run?.transcriptResult = .text
            return race(racer)
        case .racedTransform(let racer):
            guard state.run?.transformPending == true else { return false }
            state.run?.transformPending = false
            state.run?.transformResult = .output(clipboardWorks: true)
            return race(racer)
        }
        return true
    }

    private mutating func race(_ racer: RunLifecycleModel.Racer) -> Bool {
        switch racer {
        case .escape:
            guard state.escapeAvailable else { return false }
            cancelRequested()
        case .press:
            shortcut(.triggerPressed(workflowID: nil))
        }
        return true
    }

    // MARK: - Events (AppState.triggerPressed and friends)

    private func id(_ trigger: RunLifecycleModel.Trigger) -> UUID? {
        trigger == .workflow ? RunLifecycleModel.workflowID : nil
    }

    private mutating func shortcut(_ event: PipelineEvent) {
        guard state.paused == false else { return }
        perform(command(for: event))
    }

    private mutating func cancelRequested() {
        perform(command(for: .cancel))
    }

    private func command(for event: PipelineEvent) -> PipelineCommand {
        let traits = state.run.map { run in
            ActiveRunTraits(
                isRevision: run.purpose.isRevision, hotkeyMode: model.hotkeyMode,
                triggerWorkflowID: run.purpose.triggerWorkflow.flatMap(id), deliveryCommitted: run.committed
            )
        }
        return PipelineTransitions.command(for: event, in: state.pipeline, run: traits, hasLastResult: state.hasResult)
    }

    private mutating func perform(_ command: PipelineCommand, reason: RunStopReason = .hotkey) {
        switch command {
        case .ignore:
            break
        case .startRun(let workflowID):
            startRun(.dictation(workflowID == nil ? .dictate : .workflow))
        case .startRevision:
            guard state.pipeline.acceptsNewRun, state.hasResult else { return }
            startRun(.revision)
        case .stopRecording:
            requestStopRecording(reason)
        case .cancelRun:
            cancelActiveRun()
        }
    }

    // MARK: - Run start and end

    private mutating func startRun(_ purpose: RunLifecycleModel.Purpose) {
        // Keeps the model finite; see `staleLimit`.
        guard state.staleTranscripts + state.staleTransforms < RunLifecycleModel.staleLimit else {
            refusedStart = true
            return
        }
        // beginRun
        state.errorReset = false
        state.flash = false
        state.run = RunLifecycleModel.Run(purpose: purpose)
        state.pipeline = .recording
    }

    /// Set when a start was refused only to keep the model finite, so the action is dropped.
    var refusedStart = false

    private mutating func cancelActiveRun() {
        state.errorReset = false
        clearRunTracking()
        state.pipeline = .idle
    }

    /// The run's work that is still waiting outlives it; its completions must change nothing.
    private mutating func clearRunTracking() {
        guard let run = state.run else { return }
        if run.transcriptPending { state.staleTranscripts += 1 }
        if run.transformPending { state.staleTransforms += 1 }
        state.run = nil
    }

    private mutating func succeed() {
        state.pipeline = .idle
        showSuccess()
        clearRunTracking()
    }

    /// finishRunFailed for an error other than cancellation: presentError, the error reset, finishRun.
    private mutating func failRun() {
        state.flash = false
        state.pipeline = RunLifecycleModel.failure
        effects.errorsShown += 1
        state.errorReset = true
        clearRunTracking()
    }

    private mutating func showSuccess() {
        state.flash = true
        effects.flashesStarted += 1
    }

    private mutating func copy(clipboardWorks: Bool, keepsResult: Bool) {
        guard clipboardWorks else {
            state.flash = false
            state.pipeline = RunLifecycleModel.failure
            effects.errorsShown += 1
            state.errorReset = true
            return
        }
        effects.clipboardWrites += 1
        if keepsResult {
            effects.successRecords += 1
            state.hasResult = true
            state.hasPendingResult = false
        }
        state.errorReset = false
        state.pipeline = .idle
        showSuccess()
    }

    // MARK: - Recording (AppState+VoiceRun)

    private mutating func requestStopRecording(_ reason: RunStopReason) {
        guard let run = state.run else { return }
        switch (run.phase, reason) {
        case (.capturing, .hotkey) where model.hotkeyMode == .hold && run.heldLong == false:
            cancelRequested()
        case (.capturing, _):
            if reason == .hotkey, run.lastBufferQuiet == false {
                state.run?.phase = .releaseTail
            } else {
                stopRecording()
            }
        case (.releaseTail, .failure):
            stopRecording()
        case (.releaseTail, _), (.stopping, _):
            break
        }
    }

    private mutating func stopRecording() {
        state.run?.phase = .stopping
    }

    private mutating func receiveBufferLevel(quiet: Bool) {
        let level = quiet ? RunLifecycleModel.quietLevel : RunLifecycleModel.loudLevel
        state.run?.lastBufferQuiet = ReleaseTail.decision(after: .bufferLevel(dBFS: level)) == .finish
        receiveReleaseTail(.bufferLevel(dBFS: level))
    }

    private mutating func receiveReleaseTail(_ event: ReleaseTail.Event) {
        guard state.run?.phase == .releaseTail, ReleaseTail.decision(after: event) == .finish else { return }
        stopRecording()
    }

    private mutating func recordingFailed() {
        guard let run = state.run, run.committed == false else { return }
        state.run?.failed = true
        if state.pipeline == .recording {
            requestStopRecording(.failure)
        }
    }

    // MARK: - The run task

    /// Runs the run task until it waits again, as the main actor would once the action's
    /// synchronous part returns.
    mutating func settle() {
        while let run = state.run {
            switch run.position {
            case .starting:
                // openMicrophone, the run's configuration, startTranscription, then the stop.
                state.run?.transcriptPending = true
                state.run?.position = .waitingForStop
            case .waitingForStop:
                guard run.phase == .stopping else { return }
                // finishTranscription after the stop.
                if run.failed {
                    failRun()
                } else {
                    state.pipeline = .transcribing
                    state.run?.position = .waitingForTranscript
                }
            case .waitingForTranscript:
                guard let result = run.transcriptResult else { return }
                state.run?.transcriptResult = nil
                if result == .text, run.failed == false {
                    // deliverTranscript: the provider is asked.
                    state.pipeline = .translating
                    state.run?.position = .waitingForTransform
                    state.run?.transformPending = true
                } else {
                    failRun()
                }
            case .waitingForTransform:
                guard let result = run.transformResult else { return }
                state.run?.transformResult = nil
                switch result {
                case .output(clipboardWorks: true):
                    // The single commit point.
                    effects.clipboardWrites += 1
                    effects.successRecords += 1
                    state.hasResult = true
                    state.hasPendingResult = false
                    state.run?.committed = true
                    if model.autoPaste {
                        state.run?.position = .waitingForPaste
                    } else {
                        succeed()
                    }
                case .output(clipboardWorks: false):
                    state.hasPendingResult = true
                    failRun()
                case .failure:
                    effects.failedRecords += 1
                    failRun()
                }
            case .waitingForPaste:
                return
            }
        }
    }
}

extension RunLifecycleModel {
    /// The second workflow's ID; the dictate shortcut's trigger has none.
    static let workflowID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let quietLevel = -60.0
    static let loudLevel = -20.0
}
