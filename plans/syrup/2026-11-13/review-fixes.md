# Review fixes

## Goal

Resolve every finding from the three 2026-11-13 architecture reviews (GPT-6 Astra 7/10, Fable 5.2 7.5/10, Muse Wonder Full 8/10) without changing product behavior beyond the fixes themselves.

## Context

Reviewed commit `b8fb16d`. Work happens on branch `review-fixes`. Decisions made by Rafael on 2026-11-13:

- Glossary-learning judge sends only the transcript pair and comparison instruction; existing glossary terms are filtered locally.
- Usage stats stay on by default; AGENTS.md privacy rules document the store.
- Non-loopback `http` provider URLs stay allowed, with an explicit unencrypted-traffic warning in Settings.
- No local SwiftPM package split and no hosted CI. Boundaries are enforced by a grep check in `script/ci_test.sh`.

## Constraints

- AGENTS.md hard rules (privacy, secrets, clipboard, selection capture, permissions, settings).
- Swift 6 strict concurrency, Swift Testing, `xcodegen` after file adds/removes.
- Tests run through `script/test-isolated.sh` until the test host is made inert.
- No commits to `main`, no push, no release without a separate go.

## Work items

Privacy and data
1. Judge payload: pair plus instruction only; filter glossary locally.
2. RecordingArchive: propagate deletion failures, exclude entries awaiting deletion, stop admitting when retention cannot be enforced.
3. Glossary and proposal persistence: future-version guard on write.
4. Settings persistence encode failures logged.
5. AGENTS.md documents usage stats.
6. Settings warning for non-loopback `http`.

Correctness
7. Clipboard recovery keeps original and delivery text separately.
8. ClipboardWriter snapshot keeps non-string content.
9. One provider-configuration resolver; split `TransformerProviding` into factory and snapshot.
10. `DictationOptions` has no implicit on default.
11. Failure notifications reference the appended record ID.
12. Termination hook: cancel run, restore volume, flush history.
13. Codex runner: async exit wait, throwing stdin write, no SIGPIPE.
14. Precompiled cleanup regexes, no `try!` at call time.

Latency
15. Recorder starts before Accessibility captures, which run concurrently.
16. Delivery-target validation off the main actor and once per flush.
17. RecordingTee: forwarding never waits on disk writes; overflow disables archiving for the run.

Structure
18. AppState: `private(set)` state, pure transition reducer, `DeliveryCoordinator`, one failure helper, deduplicated run setup and copy actions, `userMessage(for:)` in its own file.
19. Call `ModelOutputNormalizer` directly; `TranslationError` in its own file.
20. Boundaries: glossary cap on `GlossaryList`, Settings no longer builds the audio catalog, hotkey queries through `HotkeyController`, domain types out of `Settings/`, retention-change function out of the view file, grep import check.
21. `TranscriptionRequest` replaces growing `transcribe` overloads and `preferFastResults`.
22. Nits: file/type name mismatch, revision purpose carries its base, `HistoryStore.records` `private(set)`, redundant `@unchecked Sendable`, test-only `codexPrompt` overload, KeychainStore lock, compiler warnings.

Tests
23. Test host is inert so `xcodebuild -scheme Syrup test` is safe.
24. Condition-based waits instead of yield counts; shared `TestSupport`; behavior-named test files; safe SmokeTests.

Docs
25. AGENTS.md, ARCHITECTURE.md, IMPLEMENTATION.md drift.

## Done-when

- Every item above is fixed or explicitly reported with a reason.
- `script/ci_test.sh` passes (production build plus isolated suite).
- New tests cover items 1, 2, 3, 7, 8, 9, 10, 11, 15, 17.
- Docs match the code for every drift item named in the reviews.

## Progress

- 2026-11-13: decisions recorded, branch created. Baseline: 704 tests passed.
- 2026-11-13: items 1-25 implemented. `script/ci_test.sh` passed: boundary check, production Debug build, 725 tests in 92 suites; after one more default-off prompt test, the isolated suite passed 726 tests. Key-file read at trigger time measured p50 14 us, p99 21 us, so the run resolver reads it on the main actor instead of caching (a cache would mask a corrupted key, which the secret-store tests forbid).
- Deliberate deviations: the clipboard snapshot stays text-only (reading other types asks source apps to render promised data on every write); a failed write over skipped data now reports the loss explicitly. `DeliveryTarget.isCurrent()` stays a synchronous Accessibility call, now once per typing flush instead of per keystroke step.
- Not done: grab-bag suites (`StaleAndFailedStateTests`, `PipelineSafeguardTests`) renamed but not split by subject; five unconditional "nothing else happens" yield loops remain where no completion signal exists; `AppSettings` keeps one `didSet` per property because `@Observable` does not allow property wrappers (keys are now each named once). Uncommitted on `review-fixes`.
- 2026-11-13: round-2 re-review (Astra 7.5, Fable 7.5, Muse 8) found five regressions and gaps, now fixed:
  - A trigger re-press after the delivery commit is ignored, like Esc.
  - `finishRunSucceeded` checks run ownership.
  - The clipboard loss error is limited to real loss: an item with no plain text, text over the limit, or a refused restore.
  - The judge privacy copy in Glossary settings is corrected.
  - Dictation options are frozen at the trigger.
  - Quitting waits (two seconds at most) for run cleanup and recording filing, and flushes usage stats.
  - Usage-stats writes are chained.
  - Delete All for pending recordings shows a failure notice.
  - Doc drift is fixed (TransformerSnapshot name, QA test name, Stats/Onboarding in the module maps, button names).
- `script/ci_test.sh` passed with 732 tests. Reverting the re-press guard makes `aTriggerPressDuringTheAutoPasteDelayLetsTheCommittedRunFinish` fail (no paste, no success sound).
- Larger round-2 items are handed off in `round-3-worktree-prompt.md`.
