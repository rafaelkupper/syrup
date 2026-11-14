# Review round 8: fix the round-8 review findings

## Goal

Fix the verified round-8 review findings (Astra 8.5, Fable 8.7, Muse 9 on `d01646a`), mostly shortfalls in the round-7 fixes, each with a regression test whose fake behaves like the real case. Commit and merge into the local `main` once `script/ci_test.sh` passes, then run another three-delegate review.

## Context

Branch `review-round-8`, from `main` at `d01646a`. Rafael on 2026-11-14: "Yes. do it", answering whether to fix the batch, then commit, merge into the local `main`, and run another three-delegate review. For the microphone stop, the agreed step is a real-device QA item, not a code change.

## Constraints

- AGENTS.md hard rules; Swift 6, Swift Testing; `xcodegen` after adding files; `script/ci_test.sh` must pass.
- Merge into the local `main` only; no push or release. Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md`.
- Still out of scope: AppState extraction, a frozen preferences value for `PipelineRun`, boundary-script self-tests, hotkey ordering, Codex version check, hosted CI.

## Done when

1. A CLI timeout still sends SIGKILL to the process group when the CLI exits on SIGTERM; tested with a helper that ignores SIGTERM and the default grace.
2. Download, Cancel, and Delete run one at a time per model: a new download waits for a cancelled one to stop, and nothing is promoted after cancellation; tested with a download that is slow to stop.
3. Writing or confirming a backup prunes the key's other `.unreadable` backups, including ones that already existed.
4. Only chunks with a choice reset the stream's inactivity deadline, and a streamed request has an overall cap; `{}` and usage-only chunks do not reset it.
5. Paste Last clears an error on screen once it has copied.
6. Test Connection sends the request runs send (streamed).
7. A model that rejects `temperature` is retried once without it, streamed or not.
8. Each `AppSettings` has one `PrivacyOptIns`, created by `AppSettings`; no other code can make one.
9. FluidAudio's logging is silenced once at startup, whichever engine is built first, with a test.
10. Docs and comments match (ARCHITECTURE.md lines 149, 159, 165, 197, 232; stale comments); a real-device QA item for the microphone's last buffer.
11. Small items: development-override label trims the URL; the CLI runner's unreachable fallback throws; `withOperationTimeout` runs its work off the caller's actor; JSON replies to a streamed request are normalized once; the boundary check strips strings before comments.

## Progress

- 2026-11-14: plan written. The `.unreadable` backups first appeared in `1b0d3fa` (2026-11-13 22:02), after the 1.0 build 14 release commit `0fbcd35` (11:25 the same day), so no released build wrote one; several backups per key exist only on local development builds.
- 2026-11-14: items 1 to 11 implemented with tests; the microphone item is a real-device QA check in `docs/QA.md`, as agreed.
  - Item 8 changed shape while implementing: `AppSettings` makes its one `PrivacyOptIns` (lazily; the initializer is `fileprivate`), and `AppState` attaches the history store and archive. A first version made attaching other stores a precondition failure; the full run crashed on it, because several suites (`CaretFitTests` among them) build more than one `AppState` on the same settings, each with a fresh `HistoryStore`. Attaching now replaces the stores, so the opt-outs empty the running app's stores. There is still one owner and one supersession counter per settings. Tests can set the flags before building an `AppState`, because before the attachment nothing has been kept.
  - Item 3: several backups per key exist only on development builds; they are pruned whenever that key's blob is unreadable at load, and otherwise stay until the key's next backup.
  - The first full run was cut off during the build when the session restarted (exit 137, `BUILD INTERRUPTED`, no tests ran). It left a marker and its temporary copy, which the next run's dead-run cleanup is expected to remove.
  - Full isolated run after that: 836 tests in 114 suites passed. The interrupted run's marker and temporary copy were gone, removed by the dead-run cleanup as designed.
  - First mutation check: with the CLI escalation back inside the cancellable caller and the download chain removed, both new tests still passed. The fakes were too kind: a 300 ms grace ended before the runner's 500 ms pipe wait released the cancelled caller, and the "slow to stop" wait ran inside the cancelled task, so it ended at once. With a 1 s grace and the wait in a task of its own, the same mutants fail both tests (`mostAtOnce` 2; the helper survived), and the real code passes.
  - `script/ci_test.sh` passed on the final tree: boundary check, production build, 836 tests in 114 suites, no source warnings. Committed on `review-round-8` and fast-forwarded the local `main`; not pushed. The next three-delegate review starts on that commit.
