import Testing
@testable import Syrup

/// Model checking of the run lifecycle: every state the model can reach, in hold and toggle mode,
/// with and without automatic paste, against the rules AGENTS.md and ARCHITECTURE.md set for runs.
/// `RunLifecycleConformanceTests` checks that the real `AppState` behaves as this model does.
struct RunLifecycleModelTests {
    typealias Model = RunLifecycleModel

    static let configurations: [Model] = [HotkeyMode.hold, .toggle].flatMap { mode in
        [false, true].map { Model(hotkeyMode: mode, autoPaste: $0) }
    }

    @Test(arguments: configurations)
    func everyReachableStateKeepsTheRunRules(model: Model) {
        let checker = ModelChecker(model)
        #expect(checker.stateCount > 100)
        print("RunLifecycleModel \(model.testDescription): \(checker.stateCount) states, \(checker.transitionCount) transitions")

        checker.expect("a run owns the pipeline exactly when one is active", holdsIn: { state in
            (state.run == nil) == state.pipeline.acceptsNewRun
        })
        checker.expect("recording means the run waits for its stop", holdsIn: { state in
            (state.pipeline == .recording) == (state.run?.position == .waitingForStop)
        })
        checker.expect("transcribing means the run waits for its transcript", holdsIn: { state in
            (state.pipeline == .transcribing) == (state.run?.position == .waitingForTranscript)
        })
        checker.expect("a committed run is only pasting", holdsIn: { state in
            state.run?.committed != true || (state.pipeline == .translating && state.run?.position == .waitingForPaste)
        })
        checker.expect("an error reset waits only behind an error, with no run", holdsIn: { state in
            state.errorReset == false || (state.pipeline.isError && state.run == nil)
        })
        checker.expect("the success flash shows only while idle", holdsIn: { state in
            state.flash == false || (state.pipeline == .idle && state.run == nil)
        })
        checker.expect("work in flight matches where the run waits", holdsIn: { state in
            guard let run = state.run else { return true }
            return (run.transformPending == (run.position == .waitingForTransform))
                && (run.transcriptPending == false || [.waitingForStop, .waitingForTranscript].contains(run.position))
                && run.transcriptResult == nil && run.transformResult == nil
        })
    }

    @Test(arguments: configurations)
    func everyStepKeepsTheClipboardAndCancelRules(model: Model) {
        let checker = ModelChecker(model)

        checker.expect("a committed run is never cancelled; it pastes and succeeds", holdsOnEveryStep: { from, _, to in
            from.run?.committed != true || to.run?.committed == true
                || (to.run == nil && to.pipeline == .idle && to.flash)
        })
        checker.expect("only commit and explicit copies write the clipboard", holdsOnEveryStep: { from, action, to in
            guard let effects = model.step(from, action)?.effects, effects.clipboardWrites > 0 else { return true }
            switch action {
            case .copyLast(clipboardWorks: true), .copyResultAgain(clipboardWorks: true):
                return true
            default:
                return to.run?.committed == true || (to.run == nil && to.pipeline == .idle && to.flash)
            }
        })
        checker.expect("Esc never writes the clipboard or history", holdsOnEveryStep: { from, action, _ in
            guard action == .escape, let effects = model.step(from, action)?.effects else { return true }
            return effects == Model.Effects()
        })
        checker.expect("Esc ends any run that has not committed", holdsOnEveryStep: { from, action, to in
            action != .escape || from.run?.committed == true || (to.run == nil && to.pipeline == .idle)
        })
        checker.expect("only the shortcut that started a recording stops it", holdsOnEveryStep: { from, action, to in
            guard from.pipeline == .recording, let run = from.run else { return true }
            let belongs: Bool? = switch action {
            case .press(let trigger), .release(let trigger): run.purpose == .dictation(trigger)
            case .revisionPress, .revisionRelease, .revisionMenu: run.purpose == .revision
            default: nil
            }
            return belongs != false || to == from
        })
        checker.expect("paused shortcuts change nothing", holdsOnEveryStep: { from, action, to in
            switch action {
            case .press, .release, .revisionPress, .revisionRelease: from.paused == false || to == from
            default: true
            }
        })
        if model.hotkeyMode == .hold {
            checker.expect("a hold released within 300 ms is discarded silently", holdsOnEveryStep: { from, action, to in
                guard case .release = action, let run = from.run, from.pipeline == .recording,
                      run.phase == .capturing, run.heldLong == false, from.paused == false,
                      action == .release(run.purpose == .dictation(.workflow) ? .workflow : .dictate),
                      run.purpose != .revision else { return true }
                return to.run == nil && to.pipeline == .idle && to.flash == false
                    && model.step(from, action)?.effects == Model.Effects()
            })
        }
    }

    @Test(arguments: configurations)
    func nothingGetsStuck(model: Model) {
        let checker = ModelChecker(model)
        let environment: (Model.Action) -> Bool = { $0.isUserInput == false }

        checker.expect("idle is always reachable", canAlwaysReach: { $0.pipeline == .idle && $0.run == nil })
        checker.expect("every run ends without further input, given the duration limit",
                       canAlwaysReach: { $0.run == nil }, using: environment)
        checker.expect("an error clears itself", canAlwaysReach: { $0.pipeline.isError == false }, using: environment)
        checker.expect("a cancelled run's late work drains", canAlwaysReach: {
            $0.staleTranscripts == 0 && $0.staleTransforms == 0
        }, using: environment)
    }
}

extension RunLifecycleModel: CustomTestStringConvertible {
    var testDescription: String { "\(hotkeyMode), auto-paste \(autoPaste ? "on" : "off")" }
}
