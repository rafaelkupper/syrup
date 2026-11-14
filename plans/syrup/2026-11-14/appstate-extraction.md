# AppState extraction

## Goal

Split `AppState` into owners that each hold their own state and rules, with no change in behavior. `AppState` keeps the run lifecycle: the pipeline state, the active run and its tasks, and the transitions between them.

## Context

- Branch `appstate-extraction`, from local `main` at `c86415a`.
- Baseline on 2026-11-14: `script/test-isolated.sh` passed 847 tests in 114 suites.
- `AppState` is about 2,000 lines in `AppState.swift` (1,053), `AppState+VoiceRun.swift` (567), and `AppState+Delivery.swift` (369), with about 50 stored properties. Review rounds 3 to 9 named it the main architectural drag and deferred this split. One reviewer advised targeting ownership boundaries rather than spreading methods across more files. `DeliveryCoordinator` and `PipelineTransitions` are the model: each owns one decision and its state.
- Mutable state in `AppState` today, grouped by what it serves:
  - Run lifecycle: `pipelineState`, `activeRun`, `runTasks`, `holdsPasteForOnboarding`, `foregroundActivityChanged`.
  - Status display: `isShowingSuccessFeedback`, `feedbackFlashTask`, `errorResetTask`, `errorResetRunID`, and their delays and sleepers.
  - Results outside a run: `pendingClipboardResult`, `pendingPasteID`.
  - Output volume: `outputVolumeWork`.
  - Speech warm-up: `preparedHotkeyLocaleIDs`, `didNotifySpeechEngineFallback`.
  - Learning archive: `recordingWork`.
  - Hotkeys: `hotkeyController`, `isHotkeyPaused`, `isFnRecordingLatched`.
  - Selection notices: `didNotifyEmptySelectionContext`, `didNotifyUntrustedSelectionContext`, `didRequestSelectionAccessibilityTrust`.

## Owners

Each owner is a `@MainActor` class in `Sources/App/`, built in `AppState.init` from the services `init` already receives. `AppState.init` and `AppState.fixture` keep their signatures. `AppState` keeps a one-line forward for every member that views, `HotkeyController`, or tests use, so no call site outside `Sources/App/` changes.

1. `OutputVolumeChain` (output-volume chain).
   - State: the `OutputDucker` and the newest queued change (`outputVolumeWork` today).
   - Rules: every change waits for the one before it; a failure is logged by code only and never fails a run; with no ducker, nothing is queued.
   - Interface: `lower()`, `restore()`, `restoreAfterCrash()`, `pending`.
2. `StatusIndicator` (success flash, error reset, recording-cue sync, menu bar symbol).
   - State: the observable success flag, the flash task, the error-reset task and the run it belongs to, the recording cue.
   - Rules: the success sound and flash; an error clears itself after the delay unless a run started or a newer error replaced it; the cue and the menu bar symbol map the pipeline state and the flash. Every assignment to the flag re-applies the cue, as the `didSet` does today.
   - Reads from `AppState` through `StatusIndicatorSource`: the pipeline state, the cue caption, and `clearErrorAfterDelay()`, which returns to idle only while no run is active.
3. `ResultActions` (Copy and Paste Last).
   - State: the observable result kept for Copy result again (`PendingClipboardResult` moves here), and the newest Paste Last request.
   - Rules: last result and last successful result from history, transcript fallback, the `canCopy...` flags, Copy last, Copy result again, Copy transcript instead, history copy, Paste Last.
   - Uses `StatusIndicator` for the flash and error reset, `DeliveryCoordinator` for pasting, and `ResultActionsHost` (implemented by `AppState`) for the pipeline state, `appendRecord`, `presentError`, and the two transitions copying makes: back to idle, and clearing an error on screen.
   - The commit point stays in `AppState+Delivery.swift`; it stores a failed write's result in `results.pendingClipboardResult` instead of on `AppState`. `clearRunTracking()` calls `results.cancelPendingPaste()`.
4. `SpeechReadiness` (the speech side of hotkey refresh).
   - State: the locales already prepared for bound workflows, and whether the model fallback notice was shown this launch.
   - Rules: warm the dictation locale and downloadable model of the active workflow and of every voice workflow bound to a shortcut or app route; refresh the active locale at launch; choose a run's model, falling back to Apple's when it is not ready.
5. `RecordingFiler` (the learning archive's side of a run).
   - State: the archive and the filing tasks still running after their run ended (`recordingWork` today).
   - Rules: open a provisional entry and tee the audio only while learning is on; after delivery, commit once the WAV is complete and Apple's transcript is known, unless learning was turned off meanwhile; discard on failure or cancel.

`AppState` composes them as `let` properties (`outputVolume`, `status`, `results`, `speech`, `recordingFiler`). `waitForPendingWork()` and `prepareForTermination()` gather `runTasks`, `recordingFiler.work`, and `outputVolume.pending` in the same order as today.

### What stays in `AppState`, and why

- The run lifecycle: `pipelineState` (still `private(set)`), `activeRun`, `runTasks`, event handling through `PipelineTransitions`, starting, finishing, cancelling, `presentError`, `appendRecord`, termination. This is the one owner of the pipeline; the extracted owners call back into it only through named transitions.
- The voice run phases and the recording stop rules (release tail, minimum hold, duration limit, early transformation). They act on `PipelineRun` state and the run's ownership checks; moving them would only replace `self` with callbacks.
- Transformation, streaming, and the single commit point in `AppState+Delivery.swift`, unchanged apart from where the pending result is stored.
- The hotkey glue: `hotkeyController`, `isHotkeyPaused`, `isFnRecordingLatched`. `HotkeyController` already owns registration and Fn gestures. What remains reacts to pipeline state changes (cancel shortcut, Fn latch) or cancels the run (pause), so it belongs where the pipeline state lives. The speech warm-up that `refreshWorkflowHotkeys` triggers moves to `SpeechReadiness`.
- The three selection notice flags. They are read only inside `resolveRunContext`, between ownership checks that must stay where they are.

## Constraints

- No behavior change. Every assertion in the 847 baseline tests still holds. Keep the single delivery commit point, the run-ownership checks, and the cancellation semantics exactly as they are, including the order of side effects and of `pipelineState` assignments (each assignment re-applies the cue and the cancel shortcut).
- Observation: properties the UI reads (`menuBarSymbol`, `canCopyPendingResult`) must stay observable after moving, so the owners holding them are `@Observable`.
- Tests: only mechanical call-site changes, each justified below. Planned: none.
- Stay in `Sources/App/` and new test files. Do not touch `Tests/SyrupTests/TestSupport.swift` or `AppState.fixture`, which another session is editing on `main`.
- Commit on `appstate-extraction` only. No push, merge, or release. Do not run the app or touch the real microphone, clipboard, or hotkeys.
- Before moving behavior that existing tests do not pin, add characterization tests that pass on the current code.

## Steps

1. Characterization tests in `Tests/SyrupTests/AppStateCharacterizationTests.swift`, passing on `c86415a`. Commit.
2. `OutputVolumeChain`. Run `OutputDuckingTests`, `PipelineRunTests`, characterization tests. Mutation check. Commit.
3. `StatusIndicator`. Run `AppStateTriggerTests`, `AppStateResultTests`, `RecordingCueTests`, characterization tests. Mutation check. Commit.
4. `ResultActions`. Run `AppStateDeliveryTests`, `AppStateResultTests`, `AppStateFailureTests`, `AppStateSelectionTests`, `LastSuccessfulResultTests`, `RecoveryReliabilityTests`, characterization tests. Mutation check. Commit.
5. `SpeechReadiness`. Run `ParakeetPipelineTests`, `WorkflowAbilitiesTests`, `HotkeyPauseTests`, characterization tests. Mutation check. Commit.
6. `RecordingFiler`. Run `AppStateLearningTests`, `PipelineRunTests`, `ParakeetPipelineTests`, characterization tests. Mutation check. Commit.
7. Update ARCHITECTURE.md and IMPLEMENTATION.md where they describe `AppState`. Run `script/ci_test.sh`. Commit.

## Characterization tests (step 1)

Gaps found in the baseline suite, each pinned before its owner moves:

- Status: the exact sequence of cue states, with no deduplication, for a successful run, a cancel, a failed run, Copy last, a failed copy, and a run started during the success flash. The existing cue spy drops repeats and leading `.hidden`, so a missed or extra sync would pass today. Also: observers of `menuBarSymbol` hear the flash end.
- Results: a newer Paste Last supersedes one still waiting; a run that starts and ends while Paste Last waits still cancels it (both depend only on `pendingPasteID`, which no test pins). Observers of `canCopyPendingResult` hear a failed clipboard write.
- Output volume: `restoreOutputVolumeAfterCrash()` restores through the chain that `waitForPendingWork()` awaits; quitting waits for a cancelled run's restore.
- Speech: refreshing shortcuts warms the active workflow's downloadable model each time; an unchanged set of bound locales is not prepared again, and a changed set prepares every bound locale.
- Learning: `waitForPendingWork()` and quitting wait for a delivered run's recording to be filed.

## Test changes beyond new tests

None. No existing test file changed, and `AppState.fixture` and `Tests/SyrupTests/TestSupport.swift` are untouched: `AppState` keeps a forward for every member tests use (`lastResult`, `canCopy...`, the copy actions, `pasteLastResult`, `menuBarSymbol`, `AppState.menuBarSymbol(for:showingSuccess:)`, `refreshWorkflowHotkeys`, `restoreOutputVolumeAfterCrash`, `recordingArchive`), so no call site needed even a mechanical change. The only test change is the new `AppStateCharacterizationTests.swift`.

## Mutation checks

For each owner: break one rule on purpose, run the named suites, record the failing tests, restore, rerun. Every mutation was reverted before its step's commit (by diff against a saved copy for the last three owners, by reverse replacement and a check of the restored lines for the first two), its suites passed again, and every later full run used the committed code. No `MUTATION` marker remains in `Sources/`.

| Owner | Mutation | Failing tests | Restored and green |
| --- | --- | --- | --- |
| `OutputVolumeChain` | A change no longer waits for the previous one (`await previous?.value` removed) | None: survived. `OutputDucker` is an actor, and the fake holds the first write inside it, so a later change still queues behind it. Equivalent under these fakes; recorded, not chased with a timing-dependent test. | Yes |
| `OutputVolumeChain` | `pending` no longer records the queued change | `crashRecoveryRestoresThroughTheChainThatPendingWorkAwaits`, `quittingWaitsForACancelledRunsVolumeRestore`, `slowVolumeChangesNeverDelayDeliveryButPrecedeTheSuccessSound` | Yes |
| `StatusIndicator` | The flash flag no longer re-applies the cue | All six cue-sequence tests in `StatusDisplayCharacterizationTests`, plus `cueMirrorsSuccessfulRunLifecycle` and `disabledLiveTranscriptKeepsCueButSkipsPartials` | Yes |
| `StatusIndicator` | The flash flag is `@ObservationIgnored` | `menuBarObserversHearTheSuccessFlashEnd` | Yes |
| `StatusIndicator` | The error reset never clears | `aFailedRunShowsItsErrorUntilTheResetClearsIt`, `aFailedCopyShowsItsErrorUntilTheResetClearsIt`, `errorAutoReturnsToIdle` | Yes |
| `ResultActions` | `cancelPendingPaste()` does nothing, so a run no longer stops a waiting Paste Last | `aRunThatStartsAndEndsWhilePasteLastWaitsCancelsIt` (no older test caught it) | Yes |
| `ResultActions` | Paste Last's `canContinue` ignores newer requests | `aNewerPasteLastSupersedesOneStillWaiting`, `aRunThatStartsAndEndsWhilePasteLastWaitsCancelsIt` | Yes |
| `ResultActions` | `pendingClipboardResult` is `@ObservationIgnored` | `copyResultAgainObserversHearAFailedClipboardWrite` | Yes |
| `SpeechReadiness` | An unchanged set of bound locales is prepared again (dedupe removed) | `anUnchangedSetOfBoundLocalesIsNotPreparedAgain` | Yes |
| `SpeechReadiness` | Bound workflows' models are not loaded | `refreshingShortcutsWarmsTheActiveWorkflowsModelEachTime` | Yes |
| `SpeechReadiness` | The fallback notice shows on every run | `aModelThatIsNotReadyFallsBackToAppleWithOneNotice` (all six states) | Yes |
| `RecordingFiler` | | | |

## Done when

- The five owners exist with the state and rules listed above, and `AppState` composes them.
- `script/ci_test.sh` passes: boundary check, production build, and the isolated suite with 847 baseline tests plus the new ones.
- Each owner has a recorded mutation check.
- ARCHITECTURE.md and IMPLEMENTATION.md describe the new structure.
- Commits are on `appstate-extraction` only.

## Progress

- 2026-11-14: baseline 847 tests passed. Plan written.
- Step 1: 16 characterization tests pass on the unchanged code; full run 863 tests, 858 passed and 5 skipped by their environment gates (Apple model smoke, real mishearing probes, release timing), as in the baseline. Per-test results are compared with this run after every step, from the `.xcresult` bundles.
- Step 2: `OutputVolumeChain` extracted. Full run identical to step 1.
- Step 3: `StatusIndicator` extracted. Full run identical to step 1.
- Step 4: `ResultActions` extracted. The moved code was diffed against the old section: apart from the host calls listed under Owners, the only addition is `cancelPendingPaste()`. Full run identical to step 1.
- Step 5: `SpeechReadiness` extracted; `AppState` no longer stores `speechModels`, which nothing outside these methods read. Full run identical to step 1.
