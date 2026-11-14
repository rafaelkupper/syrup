# Review round 6: fix the round-5 findings

## Goal

Fix the verified round-5 review findings (Astra, Fable, Muse, all 8.5/10 on `review-round-5`), each with a test where code changed, commit and merge rounds 5 and 6 once `script/ci_test.sh` passes, then run another three-delegate review.

## Context

Same branch as round 5 (`review-round-5`, from `main` at `13bdc29`). Rafael on 2026-11-14: "Yes, fix everything then start a new 3 delegate review", answering whether to fix the batch and then commit and merge both rounds once CI passes. Round-5 decisions still hold: turning Keep history on does not save results made while it was off; Paste Last with automatic paste off only copies.

## Constraints

- AGENTS.md hard rules; Swift 6, Swift Testing; `xcodegen` after adding files; `script/ci_test.sh` must pass.
- Merge into the local `main` only; no push or release. Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md`.
- Still out of scope: AppState extraction, moving AppSettings, CI and boundary-script self-tests, hotkey ordering, Codex version check, volatile transcript tail.

## Done when

1. A streamed chunk with an `error` object or `finish_reason: "error"` fails the run (`providerReportedError`), even when `[DONE]` follows.
2. Streams stop at 8 MB (`responseTooLarge`), which also bounds a line without an end; the atomic oversize error is the same.
3. A non-streamed request has one 30-second deadline for headers and body together.
4. Retry composes custom and revision instructions from saved parts (`TransformationSnapshot.CustomPrompt`, the adjustment); only older custom records are parsed, from the last header after a blank line. Glossary terms are one line.
5. Paste Last with no captured editor says why, like a run does; the untrusted test captures nothing.
6. `persistHistory` and `glossaryLearningEnabled` are `private(set)` with one mutator each in `AppSettings`; the Privacy pane uses it; an older failed opt-out cannot undo a newer choice.
7. Test preference domains live under `org.syrup.tests.<token>.`; cleanup matches only that and the host prefix, uses run markers with a liveness check in a fixed folder, and removes killed runs' temporary copies.
8. The locale refresh applies only to the workflow it checked, and only if its locale is unchanged; startup and Settings share it.
9. Claude failure text is matched on Claude's last stdout line plus stderr.
10. The unreachable provider fallback and clipboard check are gone, the invariant stated.
11. The streaming-speech ordering test is deterministic.
12. Docs match; CLI runs log as `CLIProvider` with `tool=`.
13. A model download replaces an incomplete folder at its destination.

## Progress

- 2026-11-14: all items implemented with tests.
  - Not followed as suggested: Fable's "match Claude failures on stderr only". Claude Code 2.1.323 prints "Not logged in · Please run /login" on stdout with nothing on stderr (checked with an empty config folder), so stderr only would lose sign-in detection. The last stdout line is used instead.
  - `lastResult` stays internal: ten tests read it.
  - Removed a 1.5 GB temporary test copy (`syrup-tests.2omuzM`, 2026-11-13) a killed run had left; nothing had it open. No old-format test preference files remained.
  - First full run: 800 of 801 passed; the one failure was a test setup mistake (adding a workflow makes it active), fixed.
  - `script/ci_test.sh` passed: 802 tests in 114 suites, no warnings; no test preference files or temporary copies left behind.
