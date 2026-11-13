# Review fixes implemented on 2026-09-07

All 13 review findings and six improvement areas are implemented. The production Debug build passes, and the isolated suite passes 339 tests in 37 suites. The review baseline was 317 tests. No deployment or live provider request was made. Unrelated local changes were preserved.

## Coverage

| Review finding | Change | Evidence |
| --- | --- | --- |
| 1. Capture starts after cancellation | Permission and capture generations invalidate superseded starts | Cancellation while permission is suspended leaves capture stopped |
| 2. Old cleanup overwrites a new run | PipelineRun owns tasks and stop state; cleanup and callbacks verify run identity after suspension | A failed run held in archive cleanup cannot change a healthy replacement run |
| 3. Active WAV deletion and premature publication | Archive tracks active IDs; sidecars publish after successful delivery and WAV completion | Pending listing preserves active WAV; failed and canceled runs never publish; archive completion does not delay delivery |
| 4. Live recognition failures wait for release | Audio feed and speech-result monitoring run together; error stops capture and wakes the pipeline | Early recognition failure stops without release; monitor error cancels an open feed |
| 5. Final audio callbacks discarded | Normal finish drains callbacks before closing; cancel discards; shutdown runs off the main actor | Fake capture final-callback test and existing converter-tail tests; real microphone tail needs smoke testing |
| 6. Delivery reaches the wrong editor | Pin process and focused AX element at trigger; check before paste and streamed flushes; expose an opt-out | Same-app field change stops typing; focus change during paste delay preserves clipboard and suppresses paste |
| 7. Learning competes with dictation | Foreground activity prevents or cancels learning; decoder cancellation flag and model release | Foreground gate, interrupted pass, release, and no charged retry tests |
| 8. Judge failures starve newer entries | Both failure stages consume attempts, back off, and retire after three failures | Real archive fixture processes seven distinct entries over consecutive passes; repeated judge failures retire an entry |
| 9. Empty pass redownloads a removed model | Check eligible work before model acquisition; explain later download behavior in Settings | Empty queue leaves model acquisition count at zero |
| 10. Provider settings change an active run | Snapshot selected endpoint/model/key or executable/model plus run preferences | URLProtocol fixture confirms the original endpoint and model after settings change |
| 11. Locale preparation cancels other locales | Independent, deduplicated per-locale tasks and selection-specific status | Out-of-order locale completions preserve selected status and start once per normalized locale |
| 12. History deletion failure appears successful | Ordered off-main writes, deletion barriers, visible errors, opt-in preserved on failure | Unwritable-directory fixture, disk reload order, queued-write deletion barrier, and existing round-trip tests |
| 13. Notification copies a different record | Copy resolves its originating UUID and validates eligibility | Two failures plus an unknown UUID copy only the requested transcript |

Additional improvements include passive output preview without auto-paste, a first-visible-output metric, independent accuracy and preview preferences, bounded 256-buffer audio handoffs, 15-second timeouts for speech finalization and result collection, and off-main selection capture with a 100 ms per-message Accessibility deadline. Tests cover passive preview cancellation, explicit overflow, accurate defaults, final callbacks, and timeout cleanup even when the underlying task ignores cancellation.

Apple On-Device revisions avoid prewarming an empty placeholder instruction. Context-bearing Apple runs prepare after selection capture, and the transformer creates a fresh session whenever the actual instruction differs from its prepared instruction.

## Validation

- `xcodegen`: passed. The generated project was not edited directly.
- `xcodebuild -scheme Syrup -configuration Debug build`: BUILD SUCCEEDED with the production application entry point and signing configuration.
- `SYRUP_TEST_ROOT=/tmp/syrup-implementation-tests script/test-isolated.sh`: TEST SUCCEEDED, 339 tests in 37 suites, 1.125 seconds reported by Swift Testing.
- Optimized storage fixture: one test passed. Debug configuration with `SWIFT_OPTIMIZATION_LEVEL=-O`, `GCC_OPTIMIZATION_LEVEL=s`, and coverage disabled.
- `git diff --check`: passed.

The isolated host has an inert SwiftUI entry point, a separate bundle ID, and ad-hoc signing. It does not activate production hotkeys, startup retention maintenance, scheduled learning, or model downloads. CI now builds production before invoking this isolated suite. This validates the real component code but does not replace production bootstrap and permission smoke tests.

The known CoreSimulator version mismatch and skipped AppIntents metadata extraction warnings remain environmental warnings; macOS build and test actions succeeded. No tests were disabled to make the suite pass. Existing expectations were updated for deliberately asynchronous selection/archive completion and the new bounded judge retry contract.

## Performance

Temporary local fixtures used the same record sizes and warmup as the review. A full history contains 20 records, each with the stated number of characters in both transcript and output. History samples exclude the first 20 appends and report the following 30. Archive listing uses 100 samples across 50 entries with 4,000-character transcripts.

| Operation | Before median | After median | After p95 |
| --- | ---: | ---: | ---: |
| List 50 archived recordings | 3.71 ms | 3.486 ms | 3.725 ms |
| Main-actor history append, 4,000 characters per field | 0.62 ms | 0.0018 ms | 0.0046 ms |
| Main-actor history append, 100,000 characters per field | 7.49 ms | 0.0071 ms | 0.0102 ms |
| Append through completed file write, 4,000 characters per field | 0.62 ms | 0.600 ms | 0.654 ms |
| Append through completed file write, 100,000 characters per field | 7.49 ms | 7.638 ms | 41.131 ms |

The improvement is removal of synchronous storage work from the main actor and delivery path. Total file-write cost is broadly unchanged; the large-record run had a higher tail than the baseline p95 of 8.10 ms. That work now runs on the disk actor, although clear, opt-out, and orderly quit intentionally wait for it. These are short microbenchmarks, not an end-to-end speed or recognition-quality claim. Completed writes here mean the file API returned, not a power-loss durability guarantee.

## Remaining manual verification

Use the added checklist in `docs/QA.md` for signed-app microphone permission/cancellation, quiet final words, hardware routing, real AX field/tab identity, secure fields, stalled selection targets, passive preview, Whisper release latency, and accurate-versus-fast recognition quality. No consented audio comparison or live editor injection was performed. The 100 ms AX deadline bounds individual requests, not total selection latency. Speech timeout recovery requests framework cancellation; actual framework resource release still needs hardware verification.

Detailed logs, the optimized benchmark source, and the final xcresult are retained in the task's `syrup-review/implementation-evidence` artifact folder.
