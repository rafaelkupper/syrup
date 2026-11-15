# State machines

Syrup has 125 state machines, most of them implicit: Bool flags, optional tasks, request IDs, continuations, timers, and files on disk rather than an enum. Each area document below has a statechart for every machine with history worth drawing. Two machines that guard AGENTS.md's hardest rules are formally validated with a model: the run lifecycle, and the Fn key and dictate shortcut. Each is model-checked exhaustively and replayed against the real code. The run lifecycle kept every rule checked. The Fn machine broke three, findings F1 to F3 below; all three were fixed on 2026-11-15, and it now keeps every rule too. The speech model machine is validated without a separate model: its tests explore the production `SpeechModelMachine` itself over every reachable state and replay the transitions on the real `SpeechModelManager` ([M01 in speech-learning.md](speech-learning.md#m01-download-load-and-remove-queue)). A third model-checked machine, the glossary-learning opt-out, is gone: its model, `LearningOptOutModel`, was dropped on 2026-11-15, when this work was rebased onto `main` after the feature's removal (`a3dec87`, 2026-11-14).

Inventory and validation date: 2026-11-14, on branch `state-machines`. F1 to F3 fixed and the Fn model revalidated on 2026-11-15, on branch `fn-shortcut-fixes`. On 2026-11-15 the four area documents were checked again against `5386bbc`, after glossary learning was removed and the speech model manager became an explicit machine. The test suites were not run for that update; the speech model counts in speech-learning.md come from running the explorer's code at `5386bbc` outside the suite.

| Area | Document | Machines | Formally validated |
| --- | --- | --- | --- |
| Run pipeline (`Sources/App/`) | [run-pipeline.md](run-pipeline.md) | 12 charted, 6 small | Run lifecycle, success flash, error reset, Copy result again |
| Input and output devices (`Hotkey`, `Paste`, `Audio`, `RecordingCue`, `Clipboard`, `Context`) | [input-output.md](input-output.md) | 19 charted, 9 small | Fn key and dictate shortcut |
| Speech models and glossary checks (`Transcription`, `Learning`) | [speech-learning.md](speech-learning.md) | 25 charted, 3 small | Speech model machine, explored exhaustively, with the retired-model handover |
| Providers, persistence, settings, and the app shell | [providers-persistence-shell.md](providers-persistence-shell.md) | 43 charted, 8 small | None |

## How the validation works

Each model-checked machine has a finite model in `Tests/SyrupTests/StateMachines/`, written as a Swift value type whose actions are everything that can happen from outside: keys, menu items, buffer levels, timers, async completions, and cancellation. `ModelChecker` explores every reachable state breadth-first, the technique TLC uses, and checks three kinds of property, each with the shortest counterexample when it fails:

- invariants, which must hold in every reachable state;
- step rules, about what one action may change, such as "Esc never writes the clipboard";
- stuck states: from every reachable state some goal stays reachable, optionally using only timers and completions, so "without further input, every run ends" can be checked.

Where production already has a pure decision function, the model calls it instead of restating it (`PipelineTransitions.command`, `ReleaseTail.decision`, the Fn thresholds, `AppState.minimumHold` through a guarded copy).

A model is only as good as its match with the code, so each one is replayed against the real types: a walk through the model is performed on the real `AppState` and `HotkeyController`, with a transcriber, provider, timers, clock, and microphone the test controls. After every step the real app's observable state must match the model's, including the work still in flight, and the first difference fails the test with the path that reached it.

| Model | States | Transitions | Replay by default (every state) | Full replay (every transition) |
| --- | --- | --- | --- | --- |
| `RunLifecycleModel`, hold and toggle, automatic paste off and on | 797 to 1,097 each | 11,344 to 15,294 each | 6,931 steps | 134,652 steps |
| `FnShortcutModel`, hold and toggle | 1,908 and 1,944 | 17,820 and 18,072 | 4,967 steps | 110,697 steps |

Run the default checks with the rest of the suite (`script/test-isolated.sh`). For the full replay, which takes a few minutes, run `TEST_RUNNER_SYRUP_FULL_CONFORMANCE=1 script/test-isolated.sh -only-testing:SyrupTests/RunLifecycleConformanceTests -only-testing:SyrupTests/FnShortcutConformanceTests`.

The speech model machine needs no model of its own. `SpeechModelExplorerTests` runs the production `SpeechModelMachine` breadth first over every interleaving of clicks and job steps on a simulated disk, and `SpeechModelConformanceTests` replays the explored transitions on the real `SpeechModelManager` with a real folder. Both run with the rest of the suite; [M01 in speech-learning.md](speech-learning.md#m01-download-load-and-remove-queue) gives the counts and what is left out.

### What each model covers

- **Run lifecycle** (`RunLifecycleModel`): dictation from the dictate shortcut and a workflow shortcut, revision, Esc, pausing shortcuts, the minimum hold, quiet and loud buffers, the release tail, the duration limit, microphone and recognizer failures, empty transcripts, the provider, the clipboard refusing a write, the single commit point, automatic paste, the success flash, the error reset, Copy last, Copy result again, late completions of cancelled runs, and a completion racing a key press. Left out: selected-text and retry runs, Paste Last, streamed delivery, and early transformation.
- **Fn key and dictate shortcut** (`FnShortcutModel`): Fn taps, holds, double-taps, and combinations through `FnKeyGesture`, `HotkeyController`'s Fn rules (the run Fn started, the hold-mode latch, toggle-mode arming), the Fn option, pausing, typing in Syrup's own fields, the dictate shortcut, Esc, and the pipeline as these see it. Time moves in 0.125 s ticks.

### Rules checked

Run lifecycle, all holding: a run owns the pipeline exactly while one is active; recording, transcribing, and translating each match where the run task waits; a committed run is never cancelled and always pastes and succeeds; only the commit and explicit copies write the clipboard; Esc never writes the clipboard or history; Esc ends any run that has not committed; only the shortcut that started a recording stops it; paused shortcuts change nothing; a hold released within 300 ms is discarded silently; an error reset waits only behind an error; the success flash shows only while idle; idle is always reachable; every run ends without further input, given the duration limit; errors clear themselves; a cancelled run's late work drains.

Fn key and dictate shortcut, all holding since the F1 to F3 fix: nothing records while shortcuts are paused; Fn, time, and completions alone can always end a recording Fn started (F1); Home shows a latch only while a latched run records, and the latch never outlives its run (F2); Fn's flags belong only to a run Fn started and end with it; Fn never stops or cancels a recording the shortcut started (F3); turning the Fn option off never touches work in flight or a recording Fn did not start; idle is always reachable; Fn never starts a recording while typing in Syrup; a single short Fn tap never records; in toggle mode only an armed double-tap starts a recording.

### Mutation checks

Each check was shown to fail when the behavior it guards is broken on purpose, then restored.

| Broken on purpose | Caught by |
| --- | --- |
| `PipelineTransitions`: Esc cancels a committed run | Model check: "a committed run is never cancelled" |
| `commit` no longer marks the run committed | Run lifecycle replay: the run's `committed` flag differs |
| `HotkeyController`: toggle mode arms after any tap | Fn replay |
| `RunLifecycleModel`: a new run no longer clears the flash | Run lifecycle replay (a wrong model is caught too) |

The F1 to F3 fix has its own checks, one break at a time, each restored ([plan](../../plans/syrup/2026-11-15/fn-shortcut-fixes.md#mutation-checks)):

| Broken on purpose | Caught by |
| --- | --- |
| `AppState` stops calling `pipelineStateChanged`, as before the fix | Fn replay and the F2 and F3 regression tests |
| `fnStartedRun` ends when recording stops rather than when the run ends | Fn replay; Fn with another key no longer cancels its run during transcription |
| Turning Fn off cancels a recording in its release tail | `turningFnOffDuringTheReleaseTailLetsTheRunFinish` |
| Turning Fn off cancels a run that is not recording | `turningFnOffLeavesASelectionRunFnStartedToFinish` |
| Turning Fn off ignores a toggle run Fn started | Fn replay and the F1 toggle test |
| A double-tap latches a run whatever its state | `aDoubleTapDoesNotLatchARunBeingTranscribed` (the default replay missed it; the full replay reaches it) |
| The latch survives the end of its recording | Fn replay and the F2 regression tests |
| The toggle flag survives the end of its recording | Fn replay |
| A toggle double-tap no longer marks its run | Fn replay and the F1 toggle test |

## Findings

F1 to F3 were found by `FnShortcutModel` on 2026-11-14 and confirmed on the real `HotkeyController` and `AppState` by the replay. All three were fixed on 2026-11-15 (branch `fn-shortcut-fixes`, [plan](../../plans/syrup/2026-11-15/fn-shortcut-fixes.md)). Each fix was test-first: `FnShortcutFixTests` reproduces every finding on the real app and failed before the fix, and the model's rules, known issues until then, are now ordinary expectations. The fix keeps every earlier test and the behavior pinned in `FnShortcutFixTests`: an Fn hold already stopping, a selection run, and work in flight finish as before when the Fn option is turned off, and Fn with another key still cancels the run Fn started while it is transcribed. One edge changes on purpose: a latched run the dictate shortcut already stopped, still in its release tail when the Fn option goes off, now finishes instead of being cancelled.

- **F1, Medium, fixed. Turning the Fn option off left a recording Fn started running.** `HotkeyController.updateFnKeyMonitor` cancelled a latched Fn run when the Fn route went away, but not an ordinary Fn hold (`fnStartedRun`) or a toggle-mode run Fn started. Fn could then no longer end it; Esc, the dictate shortcut in toggle mode, or the duration limit had to. Shortest trace in hold mode: Fn down, Fn option off. Fix: a new flag, `fnStartedToggleRun`, marks a toggle recording Fn started, and stopping the monitor cancels any recording Fn started, held, latched, or toggled, while it is still capturing.
- **F2, Low, fixed. The Fn latch could outlive its run.** In hold mode a double-tap whose run was already stopped or cancelled still latched, and Home showed the latch while idle; a latch also survived a run stopped by the shortcut, Esc, or the duration limit until the next Fn event, so turning the Fn option off then cancelled the next run or a transcription. Shortest trace: Fn down, Fn up, Fn down, dictate shortcut released, Fn up. Fix: a double-tap latches only a run still recording, and `AppState` now tells the controller about every pipeline change (`pipelineStateChanged`), which ends the latch with its recording.
- **F3, Low, fixed. Stale Fn flags could end a run the dictate shortcut started.** `fnStartedRun` and the latch were not tied to a run, so after the shortcut ended Fn's run and started another, releasing Fn, Fn with another key, or a double-tap stopped or cancelled the shortcut's run. Shortest trace: Fn down, dictate shortcut released, dictate shortcut pressed, Fn up. Fix: `pipelineStateChanged` ends `fnStartedRun` when the pipeline returns to idle or error. Every run starts from idle or error, so Fn's flags end before any later run can begin, without recording run IDs.

## Suspected defects not yet verified

The inventory found these by reading the code; none has been reproduced. Each area document gives the event sequence.

- Input and output: removing a workflow while its shortcut is held drops the release, so the recording runs until Esc, pausing, or the duration limit. A key pressed within one 30 ms Fn poll reads as Fn alone. After switching from toggle to hold mode during an Fn toggle recording, Fn can no longer end it.
- Speech models and glossary checks: a cancelled Ultra handover whose old folder cannot be deleted restarts the download at the next launch; a cancelled or failed locale installation can leave Downloading or Checking on screen with nothing running.
- Providers, persistence, settings, and shell (SH1 to SH9 in that document): a failed Delete Stats reloads old numbers over a sample recorded meanwhile; onboarding's endpoint Test can report the wrong endpoint, or drop its own result; a stale key-existence check can show "Not set" after a save; CLI status and model lists from a previous path or account folder can land last; a key save that finishes after Back moves the onboarding guide; the "API key saved" message can be wiped at once; editing a CLI path keeps the old status; the "leftover history could not be deleted" notice can outlive the file. None lets data persist without an opt-in or an opt-out claim success while data remains.

## Adding a model

Write a `StateMachineModel` whose actions are the machine's inputs, call production's pure decision functions where they exist, check its rules with `ModelChecker`, and replay `ConformanceCoverage.tour(for:)` against the real type with fakes the test controls, comparing everything observable after each step, including work in flight. Then break one rule on purpose and confirm a test fails.
