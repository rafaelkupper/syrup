import Testing
@testable import Syrup

/// Model checking of the Fn key and the dictate shortcut, in hold and toggle mode, against the rule
/// AGENTS.md sets for shortcuts: a recording must never be left running because the key that would
/// end it can no longer be seen.
struct FnShortcutModelTests {
    typealias Model = FnShortcutModel

    static let configurations = [Model(hotkeyMode: .hold), Model(hotkeyMode: .toggle)]

    @MainActor @Test func theModelUsesTheAppsMinimumHold() {
        #expect(Model.minimumHold == AppState.minimumHold)
    }

    @Test(arguments: configurations)
    func theFnKeyCanAlwaysEndARecordingItStarted(model: Model) {
        let checker = ModelChecker(model)
        print("FnShortcutModel \(model.hotkeyMode): \(checker.stateCount) states, \(checker.transitionCount) transitions")
        // Finding F1 (2026-11-14, fixed 2026-11-15): turning the Fn option off left an ordinary Fn
        // hold, or a toggle run Fn started, recording with no Fn way to end it. Shortest: fnDown ->
        // fnOptionOff.
        checker.expect("a recording Fn started ends with Fn, time, and completions alone",
                       canAlwaysReach: { state in
                           if case .recording(_, byFn: true) = state.app { return false }
                           return true
                       },
                       using: { $0.isFnOrTime || $0.isCompletion })
    }

    @Test(arguments: configurations)
    func everyReachableStateKeepsTheShortcutRules(model: Model) {
        let checker = ModelChecker(model)
        checker.expect("nothing records while shortcuts are paused", holdsIn: { state in
            state.paused == false || state.app.isRecording == false
        })
        // Finding F2 (2026-11-14, fixed 2026-11-15), hold mode: a double-tap that completed after its
        // run was already stopped or cancelled still latched, and Home showed the latch while idle.
        // The latch also outlived a run stopped by the shortcut, Esc, or the duration limit until
        // the next Fn event. Shortest: fnDown -> fnUp -> fnDown -> dictateRelease -> fnUp.
        checker.expect("Home shows a latch only while a latched run records", holdsIn: { state in
            state.latchedMirror == false || (state.latched && state.app.isRecording)
        })
        checker.expect("the Fn latch never outlives its run", holdsIn: { state in
            state.latched == false || state.app.isRecording
        })
        checker.expect("Fn's flags belong only to a run Fn started, and end with it", holdsIn: { state in
            switch state.app {
            case .idle, .error:
                state.fnStartedRun == false && state.latched == false && state.fnStartedToggleRun == false
            case .busy:
                state.latched == false && state.fnStartedToggleRun == false
            case .recording(_, let byFn):
                byFn || (state.fnStartedRun == false && state.latched == false && state.fnStartedToggleRun == false)
            }
        })
        checker.expect("idle is always reachable", canAlwaysReach: { $0.app == .idle })
    }

    @Test(arguments: configurations)
    func everyStepKeepsTheShortcutRules(model: Model) {
        let checker = ModelChecker(model)
        checker.expect("Fn never starts a recording while typing in Syrup", holdsOnEveryStep: { from, action, to in
            guard from.typingInSyrup, from.app.isRecording == false, case .recording(_, byFn: true) = to.app else { return true }
            return [.dictatePress].contains(action)
        })
        checker.expect("turning the Fn option off never touches work in flight or a recording Fn did not start",
                       holdsOnEveryStep: { from, action, to in
            guard action == .fnOptionOff else { return true }
            switch from.app {
            case .recording(_, byFn: true): return to.app == .idle
            default: return to.app == from.app
            }
        })
        if model.hotkeyMode == .hold {
            checker.expect("a single short Fn tap never records", holdsOnEveryStep: { from, action, to in
                guard action == .fnUp, from.fnStartedRun, case .active(let age, followsTap: false) = from.gesture,
                      Double(age) * Model.tick < FnKeyGesture.maximumTap else { return true }
                return to.app.isRecording == false
            })
            // Finding F3 (2026-11-14, fixed 2026-11-15): HotkeyController's "Fn started the run" flag
            // and its latch were not tied to a run, so after the shortcut ended Fn's run and started
            // another, Fn could stop or cancel the shortcut's run. Shortest: fnDown -> dictateRelease
            // -> dictatePress -> fnUp.
            checker.expect("Fn never stops or cancels a recording the shortcut started", holdsOnEveryStep: { from, action, to in
                guard case .recording(_, byFn: false) = from.app, action.isFnOrTime, action != .tick else { return true }
                return to.app == from.app
            })
        } else {
            checker.expect("in toggle mode only an armed double-tap starts a recording", holdsOnEveryStep: { from, action, to in
                guard from.app.isRecording == false, case .recording(_, byFn: true) = to.app else { return true }
                return action == .fnUp && from.armed
            })
        }
    }
}

extension FnShortcutModel: CustomTestStringConvertible {
    var testDescription: String { "\(hotkeyMode)" }
}
