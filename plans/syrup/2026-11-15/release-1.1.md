# Syrup 1.1: integrate, review, merge, release

## Goal

Ship the AppState split, the state-machine models and statecharts, and the F1 to F3 Fn fixes on top of local `main`, as Syrup 1.1 build 15: reviewed, merged into `main`, pushed, built, signed, notarized, and published as a release with its feed entry.

## Context

- The work was on `fn-shortcut-fixes`, stacked on `state-machines` and `appstate-extraction`, based on `3492746`. Local `main` moved to `86008fb` meanwhile (25 commits): glossary learning removed (`a3dec87`), the speech-model manager made an explicit state machine, Delete Partial Download, provider stream fixes, and the mutation tool.
- The last release is 1.0 build 14, tag `v1.0` on `<owner>/syrup`, which is private. The feed is `appcast.xml` on `main`; `script/release.py` reads the live feed over public HTTPS, which returns 404 while the repository is private (see `docs/logs/2026-11-13-syrup-1.0-public.md`).
- The maintainer chose 1.1 on 2026-11-15. Fn behavior will be tested by hand later.

## Constraints

- No regression. The three-delegate review (Astra, Fable, Muse) must pass before the merge; fixes to its findings are red-first and re-checked.
- Leave `docs/logs/2026-11-13-syrup-1.0-public.md` and the main checkout's working tree alone.
- Everything public about the release is minimal: title and notes `Syrup 1.1`.
- Do not run the app or touch the real microphone, clipboard, or hotkeys.
- Writing: lead with the result, straight quotes, no em dashes, dates as YYYY-MM-DD.

## Approach

1. Rebase the stack onto `main` as `release-1.1`, dropping what `main`'s learning removal made moot: the `RecordingFiler` extraction, its characterization tests, and the learning opt-out model. Build, then `script/ci_test.sh`.
2. Review the code (`main..release-1.1`) with three delegates in their own worktrees, blocking only on regressions or false passes. In parallel, a writer brings `docs/state-machines/` up to date with `main`'s code; check its links, anchors, and charts.
3. Fix findings red-first, re-check, rerun CI and the full replay.
4. Fast-forward `main`, push.
5. Version 1.1 build 15, CI, `script/release.sh` (archive, export, notarize), review the artifacts, publish, verify from GitHub. Log in `docs/logs/2026-11-15-syrup-1.1.md`. Update README.md if it names the version or the removed feature.

## Done when

- Review passed with no open blocker; CI and full replay pass on the merged commit.
- `main` pushed; release `v1.1` with `Syrup-1.1.zip` and the feed entry verified; deployment log written.

## Progress

- 2026-11-15: rebased as `release-1.1` (13 commits on `86008fb`). Dropped `0c1de1b` (RecordingFiler) and `cf9e1a4` (learning opt-out model); removed `RecordingFilingCharacterizationTests` and the learning replay; conflicts in `AppState.swift`, `AppState+VoiceRun.swift`, ARCHITECTURE.md, IMPLEMENTATION.md, and the AppState plan resolved by keeping `main`'s text and re-applying the stack's edits without learning lines. The app builds.
- `script/ci_test.sh` on the rebased branch: boundary check, build, and the isolated suite passed (868 tests in 125 suites, 2 known issues: the checker's self-tests). Its mutation gate (20 of 183 mutants of the changed lines) failed on 3 survivors: `SpeechReadiness.swift:27` and `:28` (the launch locale refresh, moved from `AppState`; no test called `refreshDictationLocales()`), and `StatusIndicator.swift:143` (`errorResetTask?.cancel()` in `scheduleErrorReset`). A new test, `refreshingDictationLocalesAtLaunchSelectsTheActiveLocaleAndPreparesRoutedOnes`, kills the first two (rerun with `--only`); the third is listed in `script/mutation-equivalent.json` with its reason.
- The maintainer chose to rewrite the 55 unpushed commits to the neutral `Syrup contributors` identity before pushing, as every commit already on GitHub uses.
- Review of `main..5386bbc` (code; docs/state-machines out of scope): Astra, Fable, and Muse each PASS, no blocker. Minor findings, all fixed: a stale `RecordingFiler` doc comment in `AppState.swift` and a learning mention in `RunLifecycleModel.swift`; two manual QA checks that would pass on the unfixed code too (rewritten so the checklist claims only what a real keyboard can show); the full replay starves other tests when run with the whole suite (IMPLEMENTATION.md now says to run it alone). Fable's probes confirmed the F1 and F3 tests and the replays catch breaks in the fix; Astra and Fable each ran the full replay on the rebased head (Fn 110,697 steps, run lifecycle 134,652).
- The writer's statechart update (`70fe671`, picked onto this branch): 125 machines (was 138); learning machines removed, the speech-model machine (M01) rewritten from `SpeechModelMachine`, the launch cleanup added, anchors checked. All 105 charts parse with Mermaid 11 here (a broken control chart fails the same check), and every link and anchor resolves; removing the stale comment line shifted 26 `AppState.swift` anchors, updated with their labels.
- README.md: links to docs/state-machines/ from the developer section; nothing else was out of date (download links use `releases/latest`, and `main` had already removed the learning text).
- Full mutation run (`SYRUP_MUTANTS=200`, against `5386bbc` before the new test): stopped by the 2-hour tool limit after 124 of 183 mutants. 74 killed, 12 timed out (counted as killed), 22 did not compile, 16 survived. Three survivors are the launch locale refresh, killed by the new test (`SpeechReadiness.swift:27`, `:28`) or reached through it (`AppState.swift:254`). The other 13 are in code moved unchanged out of `AppState`: `AppState.swift:614, 702, 709, 714, 722`, `OutputVolumeChain.swift:39`, `ResultActions.swift:97, 205, 206, 210, 219, 239`, `SpeechReadiness.swift:44`. 59 mutants did not run. The maintainer chose to release now and close these afterwards on a follow-up branch with tests or equivalent entries.
- `script/ci_test.sh` on `1c9cdf2`: passed. 869 tests in 125 suites, 2 known issues; the mutation gate killed 17 with no survivor (3 did not compile); no compiler warnings.
- Version set to 1.1 build 15.
- Follow-up mutation closure (tests only): 14 new tests, one strengthened, and 10 equivalence entries. Of the 183 mutants against `e09af51`, 142 are killed (15 of them timed out), 29 do not compile, 11 are equivalent, and one survives: `StatusIndicator.swift:136`, which exposes a race already in 1.0, where a flash timer that woke just before being replaced hides the newer success checkmark. Review (Astra, Fable) caught that the commit first listed it as equivalent. The fix is a production change, made separately on `flash-race-fix` (a cancellation check in the flash task), after which that mutant is equivalent. See [the receipt](mutation-closure.md).
