# Review round 5: fix the round-4 findings

## Goal

Fix the verified round-4 review findings (Astra, Fable, Muse, all 8/10 on `13bdc29`), each with a test, then run another three-delegate review.

## Context

Branch `review-round-5` from `main` at `13bdc29`. Decisions from Rafael on 2026-11-14:

- "Keep history across restarts": turning it on does **not** save the results made while it was off.
- Paste Last: keep the AGENTS.md permissions rule as written. With auto-paste off, Paste Last must not use Accessibility.

## Constraints

- AGENTS.md hard rules; Swift 6, Swift Testing; `xcodegen` after adding files; `script/ci_test.sh` must pass.
- No commit to `main`, push, or release without a go. Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md`.
- Larger items stay out of scope: AppState extraction, moving AppSettings, CI, hotkey ordering, Codex version check, volatile transcript tail.

## Done when

1. A streamed reply ending with `finish_reason: "stop"` and EOF, without `[DONE]`, succeeds through the consumer. EOF without either marker still fails.
2. Atomic (non-streamed) responses are read through the 8 MB bounded reader.
3. Codex failure text is matched only after the echoed input.
4. No test suite writes an untokenized preference domain; the host domain is removed on exit; markers live in one place; stale test plists are removed.
5. Docs match: Codex stdout contract, the yield-wait claim, streaming as the default, SSE completion, the response cap.
6. Revise starts from the latest successful result.
7. The retired speech model stays until its replacement downloads.
8. Learning and usage-stats switches are frozen at the trigger; the delivery fallback reuses the run's provider snapshot.
9. Custom and revision retries recompose with the current glossary.
10. An empty workflow list fails to decode instead of trapping later.
11. No captured delivery target is reported as such, not as "the editor changed".
12. Clipboard restore keeps the items that fit.
13. Turning learning off deletes recordings through a model method, not a view.
14. The real on-device model test is opt-in.
15. A final SSE chunk without `delta` is accepted.
16. Quit flushes are bounded.
17. History made while persistence was off is not written when it is turned on.
18. Paste Last with auto-paste off only copies.

## Progress

- 2026-11-14: plan written, branch created.
- 2026-11-14: all 18 items implemented with tests. Notes:
  - SSE: the parser task now yields `.done` after a stop chunk at EOF; tests drive `consumeSSE` itself.
  - Clipboard: the reported all-or-nothing restore was already unreachable (each item limits itself first); the outer check now skips only the overflowing item, and a test pins it.
  - Tests: 5 yields before negative assertions became `waitForPendingWork()`. The remaining ones are press/release nudges or checks that a synchronous transition left state unchanged; ARCHITECTURE now says so instead of claiming none exist.
  - Test preferences: an age rule (over 60 minutes) replaced the TMPDIR markers, plus a delayed second pass for late cfprefsd writes. It removed about 340 stale files. Left alone: `com.rafaelkupper.*` (old bundle IDs, one may be a real install) and `syrup-uiverify-*` from a 2026-11-05 UI check.
  - No new test for the bounded quit flush; it reuses `withOperationTimeout`.
  - `script/ci_test.sh` passed: 791 tests in 114 suites; no test preference files left behind.
