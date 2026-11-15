# Close the 1.1 merge's surviving mutants

## Goal

Close every mutant of `git diff e09af51..HEAD -- Sources/` with tests or justified equivalence entries.

## Context

Started at `5ff3afd` on `t3/close-surviving-mutants`. The tool lists 183 mutants, including the existing `StatusIndicator.scheduleErrorReset` equivalence. The two existing translation equivalences are outside this diff.

## Constraints

Tests and equivalence entries only; no production changes, app launch, real microphone, clipboard, hotkeys, paid APIs, delegation, or push. Use isolated tests. Commit as Syrup contributors with the requested co-author trailer.

## Done when

- Bounded runs account for all 183 mutants with no surviving, unclassified, or unrun mutant.
- `script/ci_test.sh` passes.
- Release progress records the added coverage; changes committed locally.

## Changes

Added 14 Swift Testing declarations, including parameterized cases, and strengthened `anUnchangedSetOfBoundLocalesIsNotPreparedAgain`: the asset manager synchronously publishes `.checking` on a redundant preparation, so its state catches that mutation without a fixed sleep. Added 11 equivalence entries with exact scope, source text, occurrence, and neighboring lines. Production sources and `project.yml` are unchanged.

`OwnerBoundaryContractTests` compiles the unmodified `ResultActions.swift` and `OutputVolumeChain.swift` against boundary doubles. It observes the sentence-context request and typed error-code log without real Accessibility or OSLog delivery. Ordinary AppState tests still use `AppState.fixture` and the existing fakes. Flash tests use a task-local lifetime signal to wait for the entire older task to finish before asserting that it cannot hide a newer flash.

## Verification

Final totals: **183 unique mutants: 127 killed, 15 timed out, 29 did not compile, 12 listed as equivalent. Zero survivors, unclassified results, or unrun mutants**.

The final focused confirmation killed all 23 selected mutants: zero timeouts, non-compiling mutants, survivors, or unclassified results. Each recorded the intended assertion failure. [Assertion proofs](../../../.cache/mutation-closure-2026-11-15/proofs.json) contain the test name and failure line for each mutant.

Final `script/ci_test.sh` passed: boundary check, provider-corpus check, 50 mutation-tool tests, production build, and the isolated Swift suite. Swift Testing reported 883 tests in 127 suites with two expected checker self-test issues. Five optional test declarations were skipped, including tests in two skipped suites: release timing, real mishearing probes, and the available-model smoke test. The follow-up changes no source lines against `main`, so CI's default mutation gate has zero candidates; merge coverage below explicitly uses `--base e09af51`.

[Aggregate dispositions](../../../.cache/mutation-closure-2026-11-15/coverage.json) deduplicate exact mutant identities and use the latest completed result or matching equivalence entry. The original 182 runnable candidates were partitioned without gaps: 57 owners, 58 status/Fn, and 67 result actions. The result run was deliberately interrupted after 39 completed cases to keep it bounded; its unfinished case was discarded and rerun in a 13-case continuation, alongside a separate 15-case continuation. The original listed equivalence supplies the 183rd disposition. Every chunk finished in under 49 minutes, comfortably within the 90-minute limit. Focused confirmations overlap these candidates and are not counted twice.

Every mutation command uses `python3 -I script/mutation.py --base e09af51 --limit 200`, with `--only path:line` selectors saved beside its output. The final list validates all 12 applicable equivalences and leaves no candidate out by the limit. To rerun an individual case, for example:

```sh
python3 -I script/mutation.py --base e09af51 --only Sources/App/ResultActions.swift:210
```

| Run | Raw results |
| --- | --- |
| Owners | [owners.txt](../../../.cache/mutation-closure-2026-11-15/owners.txt) |
| Status and Fn | [tail.txt](../../../.cache/mutation-closure-2026-11-15/tail.txt) |
| Result prefix, 39 completed cases | [results.txt](../../../.cache/mutation-closure-2026-11-15/results.txt) |
| Result continuation A | [results-a.txt](../../../.cache/mutation-closure-2026-11-15/results-a.txt) |
| Result continuation B | [results-b.txt](../../../.cache/mutation-closure-2026-11-15/results-b.txt) |
| Final focused confirmation | [closure.txt](../../../.cache/mutation-closure-2026-11-15/closure.txt) |
| Final CI | [ci-final.txt](../../../.cache/mutation-closure-2026-11-15/ci-final.txt) |

Discovery runs retain their original survivor reports; the following mappings and the aggregate record their closure. Raw per-mutant suite output is in each run's adjacent `*-logs` directory. `aggregate.py --final` asserts complete coverage; `proofs.py --final` requires the named assertion failures for all 23 focused mutants. Evidence is local and ignored, not uploaded.

## Survivor mappings

Line numbers are current, confirmed by `--list`. A listed mutation applies only to its exact operator and text, not every mutation of that line.

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
| StatusIndicator:130,136,160,168, deletions | Equivalent: retaining a canceled or completed task handle cannot run a callback again; subsequent scheduling/cancellation replaces or discards it. |
| StatusIndicator:161, deletion | Equivalent: cancellation paths leave idle or a run that refuses the callback, and subsequent errors replace the retained ID before yielding. |
| StatusIndicator:165, Bool | Equivalent: both versions call `clearErrorAfterDelay` once; only disposal of the finished task and its ID differs. |
| StatusIndicator:167, deletion | Equivalent: this one-shot callback has already run; a retained ID cannot trigger it again and later schedules replace it. |
| HotkeyController:204, deletion | Equivalent: a capturing Fn run is canceled and clears the flag on idle; a stopping run cannot capture again, and leaving recording clears the private flag before a new run. |
| StatusIndicator:143, existing deletion entry | Equivalent: the superseding UUID prevents the replaced task from acting; each run schedules at most one reset. |

No real product bug was found. All newly added tests pass on unmodified production code.
