# State machines

Syrup has 138 state machines, most of them implicit: Bool flags, optional tasks, request IDs, continuations, timers, and files on disk rather than an enum. Each area document below has a statechart for every machine with history worth drawing. The three that guard AGENTS.md's hardest rules are formally validated: the run lifecycle, the Fn key and dictate shortcut, and the glossary-learning opt-out. Each is model-checked exhaustively and replayed against the real code. The run lifecycle and the opt-out keep every rule checked. The Fn machine breaks three, recorded below as findings F1 to F3 and as known issues in its tests.

Inventory and validation date: 2026-11-14, on branch `state-machines`.

| Area | Document | Machines | Formally validated |
| --- | --- | --- | --- |
| Run pipeline (`Sources/App/`) | [run-pipeline.md](run-pipeline.md) | 13 charted, 6 small | Run lifecycle, success flash, error reset, Copy result again |
| Input and output devices (`Hotkey`, `Paste`, `Audio`, `RecordingCue`, `Clipboard`, `Context`) | [input-output.md](input-output.md) | 19 charted, 9 small | Fn key and dictate shortcut |
| Speech models and learning (`Transcription`, `Learning`) | [speech-learning.md](speech-learning.md) | 33 charted, 4 small | Learning opt-out with the recording archive |
| Providers, persistence, settings, and the app shell | [providers-persistence-shell.md](providers-persistence-shell.md) | 46 charted, 8 small | Learning opt-out (`PrivacyOptIns`) |

## How the validation works

Each validated machine has a finite model in `Tests/SyrupTests/StateMachines/`, written as a Swift value type whose actions are everything that can happen from outside: keys, menu items, buffer levels, timers, async completions, and cancellation. `ModelChecker` explores every reachable state breadth-first, the technique TLC uses, and checks three kinds of property, each with the shortest counterexample when it fails:

- invariants, which must hold in every reachable state;
- step rules, about what one action may change, such as "Esc never writes the clipboard";
- stuck states: from every reachable state some goal stays reachable, optionally using only timers and completions, so "without further input, every run ends" can be checked.

Where production already has a pure decision function, the model calls it instead of restating it (`PipelineTransitions.command`, `ReleaseTail.decision`, the Fn thresholds, `AppState.minimumHold` through a guarded copy).

A model is only as good as its match with the code, so each one is replayed against the real types: a walk through the model is performed on the real `AppState`, `HotkeyController`, `PrivacyOptIns`, `RecordingFiler`, and `RecordingArchive`, with a transcriber, provider, timers, clock, microphone, and file manager the test controls. After every step the real app's observable state must match the model's, including the work still in flight, and the first difference fails the test with the path that reached it.

| Model | States | Transitions | Replay by default (every state) | Full replay (every transition) |
| --- | --- | --- | --- | --- |
| `RunLifecycleModel`, hold and toggle, automatic paste off and on | 797 to 1,097 each | 11,344 to 15,294 each | 6,931 steps | 134,652 steps |
| `FnShortcutModel`, hold and toggle | 3,204 and 2,142 | 30,616 and 20,052 | 7,302 steps | 184,954 steps |
| `LearningOptOutModel` | 340 | 1,588 | 513 steps | 4,039 steps |

Run the default checks with the rest of the suite (`script/test-isolated.sh`). For the full replay, which takes a few minutes, run `TEST_RUNNER_SYRUP_FULL_CONFORMANCE=1 script/test-isolated.sh -only-testing:SyrupTests/RunLifecycleConformanceTests -only-testing:SyrupTests/FnShortcutConformanceTests -only-testing:SyrupTests/LearningOptOutConformanceTests`.

### What each model covers

- **Run lifecycle** (`RunLifecycleModel`): dictation from the dictate shortcut and a workflow shortcut, revision, Esc, pausing shortcuts, the minimum hold, quiet and loud buffers, the release tail, the duration limit, microphone and recognizer failures, empty transcripts, the provider, the clipboard refusing a write, the single commit point, automatic paste, the success flash, the error reset, Copy last, Copy result again, late completions of cancelled runs, and a completion racing a key press. Left out: selected-text and retry runs, Paste Last, streamed delivery, early transformation, and the learning archive (modeled separately).
- **Fn key and dictate shortcut** (`FnShortcutModel`): Fn taps, holds, double-taps, and combinations through `FnKeyGesture`, `HotkeyController`'s Fn rules (the run Fn started, the hold-mode latch, toggle-mode arming), the Fn option, pausing, typing in Syrup's own fields, the dictate shortcut, Esc, and the pipeline as these see it. Time moves in 0.125 s ticks.
- **Learning opt-out** (`LearningOptOutModel`): turning learning on and off, including off and on again before the deletion starts, the opt-out's `deleteAll` succeeding or failing, runs that freeze the opt-in, open an entry, and file or discard it, and file removals that start or stop failing.

### Rules checked

Run lifecycle, all holding: a run owns the pipeline exactly while one is active; recording, transcribing, and translating each match where the run task waits; a committed run is never cancelled and always pastes and succeeds; only the commit and explicit copies write the clipboard; Esc never writes the clipboard or history; Esc ends any run that has not committed; only the shortcut that started a recording stops it; paused shortcuts change nothing; a hold released within 300 ms is discarded silently; an error reset waits only behind an error; the success flash shows only while idle; idle is always reachable; every run ends without further input, given the duration limit; errors clear themselves; a cancelled run's late work drains.

Learning opt-out, all holding: with learning off and the opt-out done, no recording is on disk; an opt-out never claims success while recordings remain; a recording begins only while learning is on; a recording is committed only while learning is on; a new recording never begins while a failed deletion is unresolved; every opt-out settles; every run ends.

Fn key and dictate shortcut: nothing records while shortcuts are paused, Fn never starts a recording while typing in Syrup, a single short Fn tap never records, and in toggle mode only an armed double-tap starts a recording. F1 to F3 below break the other three.

### Mutation checks

Each check was shown to fail when the behavior it guards is broken on purpose, then restored.

| Broken on purpose | Caught by |
| --- | --- |
| `PipelineTransitions`: Esc cancels a committed run | Model check: "a committed run is never cancelled" |
| `commit` no longer marks the run committed | Run lifecycle replay: the run's `committed` flag differs |
| `HotkeyController`: toggle mode arms after any tap | Fn replay |
| `RunLifecycleModel`: a new run no longer clears the flash | Run lifecycle replay (a wrong model is caught too) |
| `PrivacyOptIns`: a failed opt-out no longer turns learning back on | Learning replay: learning stays off with recordings on disk |
| `RecordingFiler`: commits after learning was turned off | Learning replay |

## Findings

F1 to F3 were found by `FnShortcutModel` and confirmed on the real `HotkeyController` and `AppState` by the replay. They are recorded as known issues in `FnShortcutModelTests`, so the suite passes and a fix shows up as a known issue no longer occurring. None is fixed: each changes behavior and needs a product decision.

- **F1, Medium. Turning the Fn option off leaves a recording Fn started running.** `HotkeyController.updateFnKeyMonitor` cancels a latched Fn run when the Fn route goes away, "so it must not keep the microphone open", but not an ordinary Fn hold (`fnStartedRun`) or a toggle-mode run Fn started. Fn can then no longer end it; Esc, the dictate shortcut in toggle mode, or the duration limit must. Shortest trace in hold mode: Fn down, Fn option off. `FnShortcutFindingTests` reproduces it on the real app. Likely fix: cancel any run Fn started when the monitor stops, as for a latched run.
- **F2, Low. The Fn latch can outlive its run.** In hold mode a double-tap whose run was already stopped or cancelled still latches, and Home shows the latch while idle; a latch also survives a run stopped by the shortcut, Esc, or the duration limit until the next Fn event. Shortest trace: Fn down, Fn up, Fn down, dictate shortcut released, Fn up.
- **F3, Low. Stale Fn flags can end a run the dictate shortcut started.** `fnStartedRun` and the latch are not tied to a run, so after the shortcut ends Fn's run and starts another, releasing Fn, or a double-tap, stops or cancels the shortcut's run. Shortest trace: Fn down, dictate shortcut released, dictate shortcut pressed, Fn up. Likely fix for F2 and F3 together: tie the Fn flags to the run ID they started.

Documented behavior, not a rule violation: when an opt-out's `deleteAll` fails, learning goes back on, and the run's entry stays on disk as an untracked audio file. New recordings may begin while it is there, which is consistent with learning being on; the archive removes the file at its next reconciliation after a commit.

## Suspected defects not yet verified

The inventory found these by reading the code; none has been reproduced. Each area document gives the event sequence.

- Input and output: removing a workflow while its shortcut is held drops the release, so the recording runs until Esc, pausing, or the duration limit. A key pressed within one 30 ms Fn poll reads as Fn alone. After switching from toggle to hold mode during an Fn toggle recording, Fn can no longer end it.
- Speech models and learning: a Cancel that lands after a download moved the model into place leaves it on disk while Settings shows Not downloaded; a cancelled Ultra handover whose old folder cannot be deleted restarts the download at the next launch; a cancelled or failed locale installation can leave Downloading or Checking on screen with nothing running; after a model load failure, a Retry whose folder deletion fails can publish the same broken Whisper model as Ready.
- Providers, persistence, settings, and shell (SH1 to SH9 in that document): a failed Delete Stats reloads old numbers over a sample recorded meanwhile; onboarding's endpoint Test can report the wrong endpoint, or drop its own result; a stale key-existence check can show "Not set" after a save; CLI status and model lists from a previous path or account folder can land last; a key save that finishes after Back moves the onboarding guide; the "API key saved" message can be wiped at once; editing a CLI path keeps the old status; the "leftover history could not be deleted" notice can outlive the file. None lets data persist without an opt-in or an opt-out claim success while data remains.

## Adding a model

Write a `StateMachineModel` whose actions are the machine's inputs, call production's pure decision functions where they exist, check its rules with `ModelChecker`, and replay `ConformanceCoverage.tour(for:)` against the real type with fakes the test controls, comparing everything observable after each step, including work in flight. Then break one rule on purpose and confirm a test fails.
