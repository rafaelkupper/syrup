# Review round 9: fix the round-9 review findings

## Goal

Fix the verified round-9 review findings (Astra 8.8, Fable 8.7, Muse 9 on `9bed501`): the shortfalls in the round-8 fixes and the new findings. Each gets a regression test whose fake behaves like the real case, checked to fail with the fix removed where practical. Commit and merge into the local `main` once `script/ci_test.sh` passes, then run another three-delegate review.

## Context

Branch `review-round-9`, from `main` at `9bed501`. Rafael on 2026-11-14: "Yes, do it", answering whether to fix the batch with the proposed fixes, then commit, merge into the local `main`, and run another three-delegate review.

## Constraints

- AGENTS.md hard rules; Swift 6, Swift Testing; `xcodegen` after adding files; `script/ci_test.sh` must pass.
- Merge into the local `main` only; no push or release. Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md`.
- Never touch the developer's real files from tests: anything that deletes `history.json` runs only at app launch or against a test folder.
- Still out of scope: AppState extraction, a frozen preferences value for `PipelineRun`, the folders' dependency on `Settings/`, boundary-script self-tests, hotkey ordering, Codex version check, hosted CI.

## Done when

1. Turning Keep history or glossary learning off with no stores attached fails closed: the setting stays on. Release builds attach stores once; tests re-attach only through a Debug-only path.
2. ARCHITECTURE.md lines 156 and 157 match the code, and the silent-reasoning limit is recorded.
3. Loads and Retry take turns with downloads and removals; Delete shows the model as removed at once, so a load cannot start in between.
4. A cancel or timeout after the CLI exited still signals the process group while it exists; the delayed SIGKILL first checks the group still exists.
5. Any non-empty delta field except `role` is stream progress, and `content` given as a list of parts is read.
6. The 5-minute stream limit applies only until the first answer text.
7. The temperature retry also recognizes a message naming `temperature` and a numeric code; both paths read 400, 422, and 501 bodies the same way.
8. A download cancelled while an old incomplete folder is being deleted is not moved into place.
9. The two timing-sensitive tests no longer depend on scheduling margins; the logging test leaves the logger silenced, and every FluidAudio engine silences it when built.
10. A partly downloaded Whisper model does not count as ready, and a failed load marks it failed instead of using up recordings.
11. A streamed run that typed nothing fits the clipboard with the completion-time context.
12. At launch with Keep history off, a leftover `history.json` is deleted.
13. Emptying the glossary or the proposals removes that key's `.unreadable` backups.
14. Small items: the boundary check's `RunConfiguration(` search ignores comments and strings; a corrupt `workflowListV3` falls back to a valid `workflowListV1`; the `EndpointPolicy` comment is accurate.

## Progress

- 2026-11-14: plan written.
- 2026-11-14: items 1 to 14 implemented with tests.
  - Item 1: before stores are attached, turning an opt-out on is allowed and turning it off is refused and logged by code; `attach` is a precondition once, and tests detach through `detachForTesting` (`#if DEBUG`) inside `AppState.fixture`, the one place tests build states.
  - Item 3: Delete shows the model as not downloaded at once (`remove()` no longer returns early while loading), and `startLoad()` joins `lastOperation`.
  - Item 6: the stream limit became a first-answer deadline task, cancelled by the first yielded answer text; `firstAnswerLimit` is injectable, which also fixes item 9's timing test.
  - Item 10: on a load failure the model is marked failed and background passes stop downloading it on their own; Settings' Retry calls `retryDownload()`.
  - Item 14: the boundary check's `RunConfiguration(` search now runs on `code_only` output; probes confirmed `RunConfiguration (` with a space fails the check and a comment or string mentioning it passes.
  - First full run: 6 issues in 4 tests, all test-side. Two removal tests waited for `.notDownloaded`, which Delete now shows at once, so they checked before the files went; the Whisper removal fixture lacked `coremldata.bin`; and the slow-answer test failed twice with `timedOut`. The cause: custom URL protocols share a loading thread, and the preceding endless-reasoning fake blocked it for 3 s, delaying the next test's first chunk past its limit. The endless fake now stops after 2 s, and the slow-answer test allows 2 s for a 3 s answer. Then 847 tests in 114 suites passed.
  - Mutation check: ten fixes reverted at once (opt-out refusal, removal state, group signal after exit, first-answer cancellation, temperature message match, typed-context reuse, Whisper marker, leftover history delete, empty-glossary backup removal, V1 fallback); each targeted test failed, and the tree was restored.
  - `script/ci_test.sh` passed on the final tree: boundary check, production build, 847 tests in 114 suites, no source warnings. Committed on `review-round-9` and fast-forwarded the local `main`; not pushed. The next three-delegate review starts on that commit.
