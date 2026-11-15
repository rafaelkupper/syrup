import Foundation
@testable import Syrup

/// A finite model of starting and stopping recordings with the Fn key and the dictate shortcut:
/// `FnKeyGesture` (taps, holds, double-taps, combinations), `HotkeyController`'s Fn rules (a run Fn
/// started, the hold-mode latch, toggle-mode arming, and Fn's flags ending with Fn's run), the Fn
/// option, pausing shortcuts, typing in Syrup's own fields, and `AppState`'s pipeline as these see it.
///
/// Time moves in ticks of 0.125 s, which is exact in binary and never lands on a threshold, and every
/// age stops counting at 5 ticks, past the longest threshold. Thresholds are the real constants,
/// except `HotkeyController`'s private 0.5 s toggle tap. The pipeline is `PipelineTransitions` as
/// `RunLifecycleModel` checks it, cut down to idle, recording, busy, and error, with stops that are
/// immediate (no release tail) and a run that ends when it finishes or fails.
struct FnShortcutModel: StateMachineModel {
    let hotkeyMode: HotkeyMode
    static let tick = 0.125
    static let ageCap = 5
    /// `HotkeyController.fnToggleMaximumTap`, which is private.
    static let toggleMaximumTap: TimeInterval = 0.5
    /// `AppState.minimumHold`, which is main-actor isolated; a test keeps the two equal.
    static let minimumHold: Duration = .milliseconds(300)

    enum Gesture: Hashable {
        case up
        case active(age: Int, followsTap: Bool)
        case ignoring
    }

    enum App: Hashable {
        case idle
        case recording(age: Int, byFn: Bool)
        case busy
        case error

        var pipeline: PipelineState {
            switch self {
            case .idle: .idle
            case .recording: .recording
            case .busy: .transcribing
            case .error: .error("failed")
            }
        }

        var isRecording: Bool { if case .recording = self { true } else { false } }
    }

    struct State: Hashable, CustomStringConvertible {
        var fnEnabled = true
        var paused = false
        var typingInSyrup = false
        var fnHeld = false
        var modifierHeld = false
        var gesture = Gesture.up
        /// Ticks since the last tap ended, while it could still start a double-tap.
        var tapAge: Int?
        var fnStartedRun = false
        var latched = false
        /// A toggle-mode recording Fn's double-tap started.
        var fnStartedToggleRun = false
        var armed = false
        var app = App.idle
        /// `AppState.isFnRecordingLatched`, which Home reads.
        var latchedMirror = false

        var monitorRunning: Bool { fnEnabled && paused == false }
        var escapeAvailable: Bool { paused == false && app.pipeline.allowsCancelShortcut }

        var description: String {
            var parts = ["\(app)", "gesture \(gesture)"]
            if let tapAge { parts.append("tap \(tapAge) ticks ago") }
            if fnHeld { parts.append(modifierHeld ? "Fn+modifier held" : "Fn held") }
            if fnEnabled == false { parts.append("Fn option off") }
            if paused { parts.append("paused") }
            if typingInSyrup { parts.append("typing in Syrup") }
            if fnStartedRun { parts.append("Fn started the run") }
            if latched { parts.append("latched") }
            if fnStartedToggleRun { parts.append("Fn toggled the run on") }
            if latchedMirror { parts.append("Home shows latched") }
            if armed { parts.append("armed") }
            return parts.joined(separator: ", ")
        }
    }

    enum Action: String, Hashable, CaseIterable, CustomStringConvertible {
        case fnDown, fnDownWithModifier, fnUp, keyWhileFnDown, tick
        case dictatePress, dictateRelease, escape
        case fnOptionOn, fnOptionOff, pause, resume, focusSyrupField, leaveSyrupField
        case runFinishes, runFails, errorClears, durationLimit

        var description: String { rawValue }

        /// The Fn key and time alone.
        var isFnOrTime: Bool { [.fnDown, .fnDownWithModifier, .fnUp, .keyWhileFnDown, .tick].contains(self) }
        /// Work finishing, with no further input from the person.
        var isCompletion: Bool { [.runFinishes, .runFails, .errorClears].contains(self) }
    }

    var initialStates: [State] { [State(), State(fnEnabled: false)] }

    func successors(of state: State) -> [(action: Action, next: State)] {
        Action.allCases.compactMap { action in
            var transition = FnTransition(model: self, state: state)
            guard transition.apply(action) else { return nil }
            return (action, transition.state)
        }
    }
}

private struct FnTransition {
    let model: FnShortcutModel
    var state: FnShortcutModel.State

    typealias Action = FnShortcutModel.Action

    mutating func apply(_ action: Action) -> Bool {
        switch action {
        case .fnDown, .fnDownWithModifier:
            guard state.fnHeld == false else { return false }
            state.fnHeld = true
            state.modifierHeld = action == .fnDownWithModifier
            poll(keyJustPressed: false)
        case .fnUp:
            guard state.fnHeld else { return false }
            state.fnHeld = false
            state.modifierHeld = false
            poll(keyJustPressed: false)
        case .keyWhileFnDown:
            guard state.fnHeld else { return false }
            poll(keyJustPressed: true)
        case .tick:
            age()
        case .dictatePress:
            guard state.paused == false else { return false }
            triggerPressed(byFn: false)
        case .dictateRelease:
            guard state.paused == false else { return false }
            triggerReleased()
        case .escape:
            guard state.escapeAvailable else { return false }
            cancelRequested()
        case .fnOptionOn, .fnOptionOff:
            guard state.fnEnabled != (action == .fnOptionOn) else { return false }
            let wasRunning = state.monitorRunning
            state.fnEnabled = action == .fnOptionOn
            updateMonitor(wasRunning: wasRunning)
        case .pause:
            guard state.paused == false else { return false }
            let wasRunning = state.monitorRunning
            state.paused = true
            cancelRequested()
            updateMonitor(wasRunning: wasRunning)
        case .resume:
            guard state.paused else { return false }
            let wasRunning = state.monitorRunning
            state.paused = false
            updateMonitor(wasRunning: wasRunning)
        case .focusSyrupField, .leaveSyrupField:
            guard state.typingInSyrup != (action == .focusSyrupField) else { return false }
            state.typingInSyrup = action == .focusSyrupField
        case .runFinishes:
            guard state.app == .busy else { return false }
            setApp(.idle)
        case .runFails:
            guard state.app == .busy else { return false }
            setApp(.error)
        case .errorClears:
            guard state.app == .error else { return false }
            setApp(.idle)
        case .durationLimit:
            guard state.app.isRecording else { return false }
            setApp(.busy)
        }
        return true
    }

    private mutating func age() {
        let cap = FnShortcutModel.ageCap
        if case .active(let age, let follows) = state.gesture {
            state.gesture = .active(age: min(age + 1, cap), followsTap: follows)
        }
        state.tapAge = state.tapAge.map { min($0 + 1, cap) }
        if case .recording(let age, let byFn) = state.app {
            state.app = .recording(age: min(age + 1, cap), byFn: byFn)
        }
    }

    private func seconds(_ ticks: Int) -> TimeInterval { Double(ticks) * FnShortcutModel.tick }

    // MARK: - FnKeyMonitor and FnKeyGesture

    private mutating func poll(keyJustPressed: Bool) {
        guard state.monitorRunning, let event = advanceGesture(keyJustPressed: keyJustPressed) else { return }
        handleFnKey(event)
    }

    private mutating func advanceGesture(keyJustPressed: Bool) -> FnKeyEvent? {
        switch state.gesture {
        case .up:
            guard state.fnHeld else { return nil }
            let followsTap = state.tapAge.map { seconds($0) <= FnKeyGesture.doubleTapWindow } ?? false
            state.tapAge = nil
            guard state.modifierHeld == false else {
                state.gesture = .ignoring
                return nil
            }
            state.gesture = .active(age: 0, followsTap: followsTap)
            return .pressed
        case .active(let age, let followsTap):
            guard state.fnHeld else {
                state.gesture = .up
                let heldFor = seconds(age)
                let isTap = heldFor < FnKeyGesture.maximumTap
                let completesDoubleTap = followsTap && isTap
                state.tapAge = isTap && completesDoubleTap == false ? 0 : nil
                return .released(heldFor: heldFor, completesDoubleTap: completesDoubleTap)
            }
            if state.modifierHeld || keyJustPressed {
                state.gesture = .ignoring
                return .combined
            }
            return nil
        case .ignoring:
            if state.fnHeld == false { state.gesture = .up }
            return nil
        }
    }

    // MARK: - HotkeyController

    private mutating func updateMonitor(wasRunning: Bool) {
        if state.monitorRunning {
            if wasRunning == false {
                // FnKeyMonitor.start resets the gesture; a key already down is a new press.
                state.gesture = .up
                state.tapAge = nil
                poll(keyJustPressed: false)
            }
        } else {
            // Fn could no longer end a recording it started, so it must not keep the microphone open.
            let fnHoldsRecording = state.fnStartedRun || state.latched || state.fnStartedToggleRun
            state.fnStartedRun = false
            state.fnStartedToggleRun = false
            state.armed = false
            setLatched(false)
            if fnHoldsRecording, state.app.isRecording { cancelRequested() }
        }
    }

    private mutating func setLatched(_ latched: Bool) {
        state.latched = latched
        state.latchedMirror = latched
    }

    private mutating func handleFnKey(_ event: FnKeyEvent) {
        if state.latched, state.app.isRecording == false {
            setLatched(false)
        }
        switch event {
        case .pressed:
            guard model.hotkeyMode == .hold, state.latched == false, state.typingInSyrup == false,
                  state.app == .idle || state.app == .error else { return }
            state.fnStartedRun = true
            triggerPressed(byFn: true)
        case .released(let heldFor, let completesDoubleTap):
            if state.fnStartedRun {
                state.fnStartedRun = false
                if completesDoubleTap {
                    // Only a recording can be kept open.
                    setLatched(state.app.isRecording)
                } else {
                    triggerReleased()
                }
            } else if state.latched {
                if completesDoubleTap {
                    setLatched(false)
                    triggerReleased()
                }
            } else if model.hotkeyMode == .toggle {
                toggleTap(heldFor: heldFor, completesDoubleTap: completesDoubleTap)
            }
        case .combined:
            if state.fnStartedRun {
                state.fnStartedRun = false
                cancelRequested()
            }
        }
    }

    private mutating func toggleTap(heldFor: TimeInterval, completesDoubleTap: Bool) {
        let wasArmed = state.armed
        state.armed = false
        switch state.app {
        case .recording:
            if heldFor < FnShortcutModel.toggleMaximumTap { triggerPressed(byFn: true) }
        case .idle, .error:
            if completesDoubleTap {
                if wasArmed, state.typingInSyrup == false {
                    state.fnStartedToggleRun = true
                    triggerPressed(byFn: true)
                }
            } else {
                state.armed = heldFor < FnKeyGesture.maximumTap
            }
        case .busy:
            break
        }
    }

    // MARK: - AppState

    private mutating func setApp(_ app: FnShortcutModel.App) {
        // pipelineState's willSet: leaving recording clears the latch Home shows.
        if app.isRecording == false { state.latchedMirror = false }
        state.app = app
        // pipelineState's didSet, HotkeyController.pipelineStateChanged: a latch and a toggle run's
        // flag end with the recording, and Fn's press flag ends with its run.
        if app.isRecording == false {
            setLatched(false)
            state.fnStartedToggleRun = false
        }
        if app == .idle || app == .error { state.fnStartedRun = false }
    }

    private func command(for event: PipelineEvent) -> PipelineCommand {
        let traits: ActiveRunTraits? = switch state.app {
        case .recording, .busy:
            ActiveRunTraits(isRevision: false, hotkeyMode: model.hotkeyMode, triggerWorkflowID: nil, deliveryCommitted: false)
        case .idle, .error:
            nil
        }
        return PipelineTransitions.command(for: event, in: state.app.pipeline, run: traits, hasLastResult: false)
    }

    private mutating func triggerPressed(byFn: Bool) {
        guard state.paused == false else { return }
        perform(command(for: .triggerPressed(workflowID: nil)), byFn: byFn)
    }

    private mutating func triggerReleased() {
        guard state.paused == false else { return }
        perform(command(for: .triggerReleased(workflowID: nil)), byFn: false)
    }

    private mutating func cancelRequested() {
        perform(command(for: .cancel), byFn: false)
    }

    private mutating func perform(_ command: PipelineCommand, byFn: Bool) {
        switch command {
        case .ignore, .startRevision:
            break
        case .startRun:
            setApp(.recording(age: 0, byFn: byFn))
        case .stopRecording:
            guard case .recording(let age, _) = state.app else { return }
            if model.hotkeyMode == .hold, Duration.milliseconds(Int(seconds(age) * 1000)) < FnShortcutModel.minimumHold {
                cancelRequested()
            } else {
                setApp(.busy)
            }
        case .cancelRun:
            setApp(.idle)
        }
    }
}
