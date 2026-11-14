# Review round 7: fix the round-6 findings

## Goal

Fix the verified round-6 review findings (Astra 8.5, Fable 8.5, Muse 9 on `4aa03c4`) and the shortfalls in my round-6 fixes, each with a test where code changed. Commit and merge into the local `main` once `script/ci_test.sh` passes, then run another three-delegate review.

## Context

Branch `review-round-7`, from `main` at `4aa03c4`. Rafael on 2026-11-14: "Yes and yes", answering:
1. whether to fix the round-6 batch, then commit, merge, and run another three-delegate review;
2. whether to update the AGENTS.md settings rule to list the volume-restore record and the `.unreadable` backups.

## Constraints

- AGENTS.md hard rules; Swift 6, Swift Testing; `xcodegen` after adding files; `script/ci_test.sh` must pass.
- Merge into the local `main` only; no push or release. Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md`.
- The AGENTS.md edit is limited to the settings rule.
- Still out of scope: AppState extraction, moving AppSettings or a frozen preferences value for `PipelineRun`, boundary-script self-tests, hotkey ordering, Codex version check, hosted CI, moving audio device lookup off the main actor.

## Done when

1. A cancelled streaming-speech run's leftover converter samples never reach the next session; the test drives `StreamingTranscriber` with resampling. `queuedOperations` is gone.
2. Nemotron and Unified count as installed only when every required file is present.
3. A model download can be cancelled (Cancel button, `cancel()`, Delete while downloading); a complete model already at the destination counts as downloaded.
4. Non-streamed provider requests no longer cut off a slow generation at 30 s total.
5. The opt-out mutators cannot run without the real archive and history store.
6. A superseded learning opt-out deletes nothing.
7. A successful retry stores the instruction it sent.
8. Streamed replies: a chunk without `choices` or `error` is skipped; a 200 with no event is decoded as a plain JSON answer if it is one and is an invalid response otherwise, with only whitespace or comments still a dropped connection; any `data:` chunk, reasoning included, counts as activity.
9. Stopping a CLI provider signals its whole process group.
10. Judge findings are capped in count and length and must appear in their transcripts; stored proposals are capped.
11. The clipboard snapshot reads each item's data once.
12. The missing-transformer guard shows a message; `waitForStopRecording` waits on the run it was given.
13. Paste Last that copies without pasting always gives feedback.
14. The Debug Privacy pane names the endpoint runs actually use.
15. `AudioRecorder.finish` drains its callback queue before disposing the queue.
16. Tests write no preference files, and the docs describe the cleanup as it is.
17. AGENTS.md lists the volume-restore record and the `.unreadable` backups; only the newest backup per key is kept.
18. Doc slips and small nits fixed (message period, `OperationTimeout` parameter name, onboarding key read, PRODUCT/ARCHITECTURE wording, single-yield test, hand-rolled polling loops).

## Progress

- 2026-11-14: plan written; all items implemented with tests, except item 15 (`callbackQueue.sync {}` in `AudioRecorder`), which needs a real AudioQueue and is checked by reading only.
  - Item 4 went further than the review's run-path fix: `OpenAICompatibleTransformer.transform` itself streams and collects the deltas, so pause attempts and the learning judge also lose the fixed 30-second total deadline. The non-streamed request remains for servers that refuse streaming and for the connection test.
  - Item 5: `PrivacyOptIns` (in `AppSettings.swift`, which alone can set the two settings) is built by `AppState` from its own history store and archive; the mutators take only the Bool.
  - Item 9: checked first that `Process` starts the child as its own process-group leader (child pgid 87106 = its PID, parent's 87104) and that `kill(-pid)` reached a helper.
  - Item 16, two attempts. Removing every test domain through cfprefsd at process exit did not work: with the script's sweep disabled, 22 files stayed, written 9 s after the test process ended (10:49:07 to 10:49:16), and a removed domain stays as an empty 42-byte plist that `defaults delete` reports as not found. What works is Fable's suggestion: `TestDefaults`, an in-memory `UserDefaults` subclass (every accessor the app uses routes through `object(forKey:)` and `set(_:forKey:)`, checked with a small program first), replacing every test `UserDefaults(suiteName:)`; `OutputDucker` now takes a `UserDefaults`. With the sweep disabled, a full run left one file, the host's own domain where KeyboardShortcuts saves its default shortcuts, instead of about 450. The detached 10-second pass is gone.
  - Mutation check: with the engine's session guard and the drain-loop cancellation check removed, `aCancelledRunCannotFeedItsLastSamplesToTheNextRun` and `aCallFromAnEarlierSessionIsRefused` fail.
  - First full run: 822 of 825 passed. The three failures were expectations that a run showing nothing sends a non-streamed request; updated, since every run now streams.
  - Found in my own review of the diff: a cancelled caller of the streamed `transform` got the partial text back; it now throws `CancellationError`, with a test.
