# Close the 1.1 merge's surviving mutants

## Goal

Close every mutant of `git diff e09af51..HEAD -- Sources/` with tests or justified equivalence entries.

## Context

Started at `5ff3afd` on `t3/close-surviving-mutants`. The tool lists 183 mutants, including the existing `StatusIndicator.scheduleErrorReset` equivalence. The two existing translation equivalences are outside this diff.

Line numbers in this receipt are as of `9ebd963`. The fix described at the end later added three lines to `StatusIndicator.swift` after line 122, so that file's lines from 123 on are three higher on `main`.

## Constraints

Tests and equivalence entries only; no production changes, app launch, real microphone, clipboard, hotkeys, paid APIs, delegation, or push. Use isolated tests. Commit as Syrup contributors. A real product bug is reported, not fixed here.

## Done when

- Bounded runs account for all 183 mutants with no surviving, unclassified, or unrun mutant, except where a survivor exposes a production bug.
- `script/ci_test.sh` passes.
- Release progress records the added coverage; changes committed locally.

## Changes

Added 14 Swift Testing declarations, including parameterized cases, and strengthened `anUnchangedSetOfBoundLocalesIsNotPreparedAgain`: the asset manager synchronously publishes `.checking` on a redundant preparation, so its state catches that mutation without a fixed sleep. Added 10 equivalence entries with exact scope, source text, occurrence, and neighboring lines. Production sources and `project.yml` are unchanged.

`OwnerBoundaryContractTests` compiles the unmodified `ResultActions.swift` and `OutputVolumeChain.swift` against boundary doubles in `Tests/OwnerBoundaryProbe/`. It observes the sentence-context request and typed error-code log without real Accessibility or OSLog delivery, and costs about 2 seconds. It is a stopgap for the tests-only constraint: it breaks whenever either file uses a new member of the copied types. Once production changes are allowed, replace it with two seams (pass `readsSentence` to `DeliveryTarget`'s `contextProbe`, give `OutputVolumeChain` an injectable log sink) and delete `Tests/OwnerBoundaryProbe`.

`aCancelledFlashTimerCannotHideANewerCopy` uses a task-local lifetime signal to wait for the entire older flash task to finish before asserting that it did not hide a newer flash. Its sleeper honors cancellation after waking, so it covers a timer cancelled while asleep, not one that already woke (see the race below). Deleting the cancel in `showSuccess` (line 113) fails its first case, and deleting the one in `cancelSuccess` (line 129) its second (checked in review).

## Verification

Totals: **183 mutants: 127 killed, 15 timed out (counted as killed), 29 did not compile, 11 listed as equivalent, 1 survivor** (`StatusIndicator.swift:136`, below). None unclassified or unrun. The survivor exposed a bug, fixed afterwards on `flash-race-fix`; with the fix, that mutant is equivalent and listed.

The final focused confirmation killed all 23 selected mutants, each with its intended assertion failure, and no timeouts. The 15 timed-out mutants in the discovery runs also recorded assertion failures in existing tests, so none is a kill by timeout alone (checked in review).

`script/ci_test.sh` passed on `9ebd963`: boundary check, provider-corpus check, 50 mutation-tool tests, production build, and the isolated Swift suite (883 tests in 127 suites, two expected checker self-test issues, five optional declarations skipped). The follow-up changes no source lines against `main`, so CI's default mutation gate has no candidates; the runs above used `--base e09af51`.

The runs were split into bounded chunks (owners, status and Fn, result actions in three parts), each under 49 minutes. Commands had the form:

```sh
python3 -I script/mutation.py --base e09af51 --only Sources/App/ResultActions.swift:210
```

The raw run output, per-mutant logs, and aggregation scripts (about 100 MB) stayed in the author's worktree under the git-ignored `.cache/` and were not committed.

## Survivor mappings

Line numbers are as of `9ebd963`, confirmed then by `--list`. A listed mutation applies only to its exact operator and text, not every mutation of that line.

| Source and line | Test or equivalence |
| --- | --- |
| AppState:253; SpeechReadiness:27,28 | `refreshingDictationLocalesAtLaunchSelectsTheActiveLocaleAndPreparesRoutedOnes` |
| AppState:613 | `providerCancellationAppliesTheFinalProcessingCueBeforeHiding` |
| AppState:701 | `emptySelectedTextErrorClearsAfterItsDelay` |
| AppState:708,713 | `delayedErrorClearReportsWhetherARunOwnsThePipeline` |
| AppState:721, deletion | Equivalent: new runs already cancel old resets; the only run-error paths that schedule one retain it with `keepErrorReset: true`. |
| OutputVolumeChain:39 | `pasteLastRequestsSentenceContextAndVolumeFailuresLogTheirCode` |
| ResultActions:97 | `copyLastSkipsMissingOutputBeforeAFailedRevision` |
| ResultActions:205 | `pasteLastFitsOnlyWithBothConsentAndTrust` |
| ResultActions:206, Bool | Equivalent: the flag only includes a bundle identifier in the returned tuple; this call uses only the unchanged PID. |
| ResultActions:210 | `pasteLastRequestsSentenceContextAndVolumeFailuresLogTheirCode` |
| ResultActions:219, deletion | Equivalent: the successful copy synchronously clears the old error; a later error has a fresh reset UUID and a new run cancels the obsolete reset. |
| ResultActions:239 | `pasteLastClipboardFailureClearsAfterItsDelay` |
| SpeechReadiness:44 | `anUnchangedSetOfBoundLocalesIsNotPreparedAgain` |
| AppState+VoiceRun:208, newly discovered | `releasingRecordingRestoresVolumeWhileTranscriptionStillWaits` |
| StatusIndicator:78 | `busyMenuBarSymbolsAnimate` |
| StatusIndicator:80 | `restingMenuBarSymbolsDoNotAnimate` |
| StatusIndicator:89 | `disabledRecordingCueIsExplicitlyHidden` |
| HotkeyController:75 | `installingAControllerDoesNotCancelAnExistingShortcutRecording` |
| HotkeyController:203, deletion | `disablingFnClearsTheLatchWhileARecordingIsFinishing` |
| StatusIndicator:130,160,168, deletions | Equivalent: retaining a canceled or completed task handle cannot run a callback again; subsequent scheduling/cancellation replaces or discards it. |
| StatusIndicator:136, deletion | Exposed a production bug (below). Equivalent once it was fixed: `clearSuccess` then runs only for the current, uncancelled flash. |
| StatusIndicator:161, deletion | Equivalent: cancellation paths leave idle or a run that refuses the callback, and subsequent errors replace the retained ID before yielding. |
| StatusIndicator:165, Bool | Equivalent: both versions call `clearErrorAfterDelay` once; only disposal of the finished task and its ID differs. |
| StatusIndicator:167, deletion | Equivalent: this one-shot callback has already run; a retained ID cannot trigger it again and later schedules replace it. |
| HotkeyController:204, deletion | Equivalent: a capturing Fn run is canceled and clears the flag on idle; a stopping run cannot capture again, and leaving recording clears the private flag before a new run. |
| StatusIndicator:143, existing deletion entry | Equivalent: the superseding UUID prevents the replaced task from acting; each run schedules at most one reset. |

## Fixed: a woken flash timer hid newer flashes

Found in review (Astra and Fable each reproduced it); the commit first listed `StatusIndicator.swift:136` as equivalent, which was wrong.

The success flash task (`StatusIndicator.showSuccess`) calls `clearSuccess()` after its sleep without checking cancellation or identity; the error reset has `errorResetRunID` for this, the flash has nothing. Sequence, three copies within the 1-second flash:

1. Copy A shows the checkmark. A's sleep ends and its hop back to the main actor is queued.
2. Copy B runs `showSuccess()`: it cancels A, too late, and sets `flashTask` to B.
3. A runs `clearSuccess()`: it hides B's checkmark at once and sets `flashTask = nil`, dropping B's handle.
4. Copy C cannot cancel B. When B's timer ends, it hides C's checkmark early.

Deleting line 136 keeps B's handle, so C cancels B: the mutant behaves better than the code, and no test can kill it without pinning the defect. The effect is cosmetic (the menu bar checkmark disappears early); copies, clipboard, and paste are unaffected. The code moved unchanged out of `AppState`, so 1.0 had the same race. Fixed on 2026-11-15 on its own branch, `flash-race-fix`: the flash task checks `Task.isCancelled` once it has the main actor, before `clearSuccess()`. Every replacement cancels the task first, on the main actor, so a woken but replaced timer now does nothing. `aFlashTimerThatWokeAsItWasCancelledCannotHideNewerCopies` failed before the fix at both checks, for a replacing copy and for a run in between; its sleeper returns normally after a cancel, which is the woken-timer moment. The mutation tool's one mutant of the new line is killed.
