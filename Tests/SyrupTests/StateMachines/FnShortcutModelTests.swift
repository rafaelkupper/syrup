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
        // Finding F1 (2026-11-14): turning the Fn option off cancels a latched Fn run but not an
        // ordinary Fn hold, or a toggle run Fn started. Fn can no longer end it; Esc, the dictate
        // shortcut, or the duration limit must. Shortest: fnDown -> fnOptionOff.
        withKnownIssue("F1: turning the Fn option off leaves a recording Fn started running") {
            checker.expect("a recording Fn started ends with Fn, time, and completions alone",
                           canAlwaysReach: { state in
                               if case .recording(_, byFn: true) = state.app { return false }
                               return true
                           },
                           using: { $0.isFnOrTime || $0.isCompletion })
        }
    }

    @Test(arguments: configurations)
    func everyReachableStateKeepsTheShortcutRules(model: Model) {
        let checker = ModelChecker(model)
        checker.expect("nothing records while shortcuts are paused", holdsIn: { state in
            state.paused == false || state.app.isRecording == false
        })
        // Finding F2 (2026-11-14), hold mode: a double-tap that completes after its run was already
        // stopped or cancelled still latches, and Home shows the latch while idle. The latch also
        // outlives a run stopped by the shortcut, Esc, or the duration limit until the next Fn event.
        // Shortest: fnDown -> fnUp -> fnDown -> dictateRelease -> fnUp.
        checker.expectKnownIssue(if: model.hotkeyMode == .hold, "F2: the Fn latch can outlive its run") {
            checker.expect("Home shows a latch only while a latched run records", holdsIn: { state in
                state.latchedMirror == false || (state.latched && state.app.isRecording)
            })
            checker.expect("the Fn latch never outlives its run", holdsIn: { state in
                state.latched == false || state.app.isRecording
            })
        }
        checker.expect("idle is always reachable", canAlwaysReach: { $0.app == .idle })
    }

    @Test(arguments: configurations)
    func everyStepKeepsTheShortcutRules(model: Model) {
        let checker = ModelChecker(model)
        checker.expect("Fn never starts a recording while typing in Syrup", holdsOnEveryStep: { from, action, to in
            guard from.typingInSyrup, from.app.isRecording == false, case .recording(_, byFn: true) = to.app else { return true }
            return [.dictatePress].contains(action)
        })
        if model.hotkeyMode == .hold {
            checker.expect("a single short Fn tap never records", holdsOnEveryStep: { from, action, to in
                guard action == .fnUp, from.fnStartedRun, case .active(let age, followsTap: false) = from.gesture,
                      Double(age) * Model.tick < FnKeyGesture.maximumTap else { return true }
                return to.app.isRecording == false
            })
            // Finding F3 (2026-11-14): HotkeyController's "Fn started the run" flag and its latch
            // are not tied to a run, so after the shortcut ends Fn's run and starts another, Fn can
            // stop or cancel the shortcut's run. Shortest: fnDown -> dictateRelease -> dictatePress -> fnUp.
            withKnownIssue("F3: stale Fn flags can end a run the dictate shortcut started") {
                checker.expect("Fn never stops or cancels a recording the shortcut started", holdsOnEveryStep: { from, action, to in
                    guard case .recording(_, byFn: false) = from.app, action.isFnOrTime, action != .tick else { return true }
                    return to.app == from.app
                })
            }
        } else {
            checker.expect("in toggle mode only an armed double-tap starts a recording", holdsOnEveryStep: { from, action, to in
                guard from.app.isRecording == false, case .recording(_, byFn: true) = to.app else { return true }
                return action == .fnUp && from.armed
            })
        }
    }
}

extension ModelChecker {
    /// Runs `body` as a known issue when `condition` holds, and as ordinary expectations otherwise.
    func expectKnownIssue(if condition: Bool, _ comment: Comment, _ body: () -> Void) {
        if condition {
            withKnownIssue(comment) { body() }
        } else {
            body()
        }
    }
}

extension FnShortcutModel: CustomTestStringConvertible {
    var testDescription: String { "\(hotkeyMode)" }
}
