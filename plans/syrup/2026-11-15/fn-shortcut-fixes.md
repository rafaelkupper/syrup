# Fn shortcut fixes: F1 to F3

## Goal

Fix the three defects `FnShortcutModel` found in `HotkeyController` (docs/state-machines/README.md, findings F1 to F3), with no other change in behavior.

- F1: turning the Fn option off leaves a recording Fn started running, and Fn can no longer end it.
- F2: the hold-mode Fn latch can outlive its run, and Home can show it while idle.
- F3: stale Fn flags can stop or cancel a run the dictate shortcut started.

## Context

- Branch `fn-shortcut-fixes`, stacked on `state-machines` (`9140f55`), which is stacked on `appstate-extraction`.
- `HotkeyController` keeps three Fn flags: `fnStartedRun` (Fn's press started the run and Fn is held), `isFnLatched` (a hold-mode double-tap keeps the run recording), and `isFnDoubleTapArmed`. None is tied to a run.
- Every run starts from idle or error (`PipelineTransitions` and the `acceptsNewRun` guards), so a run Fn started has ended once the pipeline is back at idle or error, and a later run can only start after that.
- A stop can leave the pipeline reading `.recording` for a while: the release tail, or `.stopping` while the recorder drains (`PipelineRun.recordingPhase`).
- A selection-input workflow started with Fn goes straight to `.translating`; Fn with another key still cancels it (`fnStartedRun`), and that must stay.
- `FnKeyHotkeyTests` builds a controller that is not installed in its `AppState`, so those tests see only what the controller does on its own.

## Constraints

- No behavior change beyond F1 to F3. Every existing assertion keeps holding.
- Red first: each regression test fails on the unfixed code before the fix.
- Break each part of the fix on purpose and confirm a test fails, one break at a time.
- Commit on `fn-shortcut-fixes` only. No push, merge, or release. Do not run the app or touch the real microphone, clipboard, or hotkeys. No paid APIs, no codex or claude CLIs.
- Writing: lead with the result, straight quotes, no em dashes, dates as YYYY-MM-DD.

## Approach

1. `AppState.pipelineState`'s `didSet` tells the controller the new state (`pipelineStateChanged`, which also takes over setting the Esc shortcut, so `AppState` still makes one call and no line moves). The controller then forgets:
   - the latch and a toggle run's flag when the pipeline leaves `.recording`;
   - `fnStartedRun` when the pipeline returns to idle or error, so Fn with another key still cancels its own run while it is transcribing or translating.
   This fixes F2 and F3: Fn's flags end with Fn's run, before any later run can start.
2. A double-tap latches only a run that is still recording (F2, first half).
3. A new flag, `fnStartedToggleRun`, marks a toggle-mode recording Fn's double-tap started. When the Fn monitor stops, the controller cancels the recording if Fn started it (held, latched, or toggled) and it is still capturing (F1). A run already in its release tail or stopping is left to finish, as is a selection run.
4. `fnStartedRun` and `fnStartedToggleRun` are set just before the trigger, as `fnStartedRun` always was; `pipelineStateChanged` clears them if the run does not record (a selection run clears the toggle flag) or ends.
5. The model follows the fixed code; the known issues become ordinary expectations, plus new rules: Fn's flags never outlive Fn's run, and turning the Fn option off never touches work in flight or a recording Fn did not start.

## Done when

- `FnShortcutModelTests` hold every rule with no known issue, including the new ones.
- Real-code regression tests for F1 (hold and toggle), F2, and F3 failed before the fix and pass after it; tests pin the behavior that must stay (release tail, selection run, Fn with another key during transcription).
- Default and full replays pass against the fixed controller.
- Each part of the fix has a recorded mutation check.
- `script/ci_test.sh` passes.
- README findings, the input-output statechart, ARCHITECTURE.md (if affected), and this plan record the fix.

## Progress

- 2026-11-15: plan written, branch created.
- Red: on the unfixed code the new `FnShortcutFixTests` failed for F1 (hold and toggle), F2 (three tests), and F3 (four cases), 14 issues, and the model tests failed 8 times with the known issues removed. The two keep-behavior tests, `FnKeyHotkeyTests`, and the Fn replay passed.
- Green: after the fix the Fn suites pass (39 tests in 5 suites with `HotkeyPauseTests`). The model shrank from 3,204 and 2,142 states to 1,908 (hold) and 1,944 (toggle), because stale Fn flags no longer exist. Default replay: 4,967 steps.
- One intended edge change beyond F1 to F3: a latched run the shortcut already stopped, in its release tail when the Fn option goes off, now finishes; the old code cancelled any latched run. It follows from cancelling only a capturing recording, which keeps an ordinary Fn hold in its tail finishing as before.
- Design choice: no run IDs. Every run starts from idle or error, so ending Fn's flags there ties them to their run. `FnKeyHotkeyTests` builds a controller that is not installed in its `AppState`; it keeps the old lazy latch check, so those tests pass unchanged.
- The ninth mutation (a double-tap latches a run in any state) first survived: the default replay visits every state, not every transition. `aDoubleTapDoesNotLatchARunBeingTranscribed` now catches it.
- Full replay, all three models together: Fn 110,697 steps (57,143 hold, 53,554 toggle), run lifecycle 134,652, learning opt-out 4,039; all pass.
- The first `script/ci_test.sh` failed at the boundary check: `pipelineStateChanged(_ state: PipelineState)` named an `App` type in `Sources/Hotkey`, which only `AppState`, `UpdateController`, and `userMessage` may be. It now takes no parameter and reads `appState.pipelineState`, as the rest of the controller does.
- `script/ci_test.sh` on the final code: boundary check passed, production build succeeded, 907 tests in 129 suites passed with 2 known issues (the checker's two deliberate self-test failures; F1 to F3 are no longer known issues), no compiler warnings. The full replay rerun on the final code gives the same counts.
- Done-when met on 2026-11-15. Not done: the manual QA items added to docs/QA.md need a real keyboard and the running app, which this task may not use; the three-delegate review that precedes a merge into `main` has not run.
- Mermaid 11 parses both rewritten Fn charts (a broken control chart fails the same check), and every link and line anchor in the edited documents resolves.

## Mutation checks

One break at a time against `FnShortcutFixTests`, `FnShortcutConformanceTests` (default replay), and `FnKeyHotkeyTests`, each restored from a backup and the sources' checksums confirmed afterwards. All nine were rerun against the final code (`pipelineStateChanged()` without a parameter) and caught. M6 was also run against the full replay alone, which catches it too (`theRealControllerTakesEveryTransitionAsTheModelDoes`).

| Broken on purpose | Caught by | Restored |
| --- | --- | --- |
| M1: `AppState` calls only `setCancelShortcutEnabled`, as before the fix | Fn replay; `aLatchEndsWithItsRunSoTurningFnOffSparesTheNextRun`, `fnDoesNotEndARunTheShortcutStartedAfterFnsRunEnded`, `turningFnOffDoesNotCancelALatchedRunThatIsBeingTranscribed` | Yes |
| M2: `fnStartedRun` ends when recording stops, not when the run ends | Fn replay; `fnWithAnotherKeyStillCancelsItsOwnRunDuringTranscription` | Yes |
| M3: turning Fn off cancels a recording in its release tail | `turningFnOffDuringTheReleaseTailLetsTheRunFinish` | Yes |
| M4: turning Fn off cancels a run that is not recording | `turningFnOffLeavesASelectionRunFnStartedToFinish` | Yes |
| M5: turning Fn off ignores a toggle run Fn started | Fn replay; `turningTheFnOptionOffCancelsARecordingFnStarted` (toggle) | Yes |
| M6: a double-tap latches whatever state the run is in | `aDoubleTapDoesNotLatchARunBeingTranscribed`, added after the default replay missed it | Yes |
| M7: the latch survives the end of its recording | Fn replay; `aLatchEndsWithItsRunSoTurningFnOffSparesTheNextRun`, `turningFnOffDoesNotCancelALatchedRunThatIsBeingTranscribed` | Yes |
| M8: the toggle flag survives the end of its recording | Fn replay | Yes |
| M9: a toggle double-tap no longer marks its run | Fn replay; `turningTheFnOptionOffCancelsARecordingFnStarted` (toggle) | Yes |
