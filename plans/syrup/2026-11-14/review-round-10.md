# Review round 10: fix the round-10 review findings, without regressions

## Goal

Fix the round-10 review findings (Astra 8.7, Fable 8.2, Muse 9 on `c86415a`), starting with the regression that left the glossary-learning comparison model unable to become ready. Change how fixes are tested so that a fix cannot break what it touches without a test failing. Commit and merge into the local `main` once `script/ci_test.sh` passes, then run another three-delegate review.

## Context

Branch `review-round-10`, from `main` at `c86415a`. Rafael on 2026-11-14: "Yes, do it. Also check if our self-learning glossary model makes sense. Why are we creating so many new errors? We need to have better tests. Regressions are unacceptable at this point. Also start the appstate work on a new thread in a separate worktree with Opus 5.5 xhigh."

- The AppState extraction runs in its own thread and worktree (branch `appstate-extraction`, from local `main` at `c86415a`). This round stays out of `Sources/App/` where it can.
- A read-only assessment of the glossary-learning design runs as a separate delegate. Its recommendation comes back to Rafael before any redesign.

Verified for this round:
- The published Whisper folder (`argmaxinc/whisperkit-coreml`, `openai_whisper-large-v3-v20240930_626MB`) holds `AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc`, `TextDecoder.mlmodelc`, `config.json`, and `generation_config.json`, and no tokenizer. Each bundle has `coremldata.bin`, `metadata.json`, `model.mil`, `analytics/coremldata.bin`, and `weights/weight.bin` (Hugging Face API listing, 2026-11-14).
- The tokenizer lives in `openai/whisper-large-v3`. WhisperKit 1.1.0 looks for it in `<tokenizerFolder>/models/openai/whisper-large-v3/`, then in the model folder. If it finds none, it downloads into `tokenizerFolder`, which defaults to `~/Documents/huggingface`.

## Why regressions kept appearing

- **Fixtures were written from the code's assumptions, not from the real artifact.** The Whisper fixture created a `tokenizer.json` that the real download never has, so the test agreed with the bug.
- **A fix changed a state machine without checking its other transitions.** Showing "not downloaded" at once on Delete re-enabled Download and let it cancel the deletion.
- **A hard rule in AGENTS.md had no test.** "A newer build's blob loads the default workflow" was asserted nowhere, so a fallback broke it silently.
- **Mutation checks proved each test caught its own bug.** They did not prove the new behavior was right in neighboring cases.
- **Batches were large, and each fix was tested alone.**

## What changes in testing

1. **Red first.** Write every regression test before its fix and run it against the unfixed code. It must fail for the reported reason. Record the failure here.
2. **Contract fixtures from real artifacts.** The Whisper tests use the published file layout above, not a hand-made folder. The download goes through an injected operation, like `SpeechModelManager.Operations`, so staging, moving, and readiness are tested end to end.
3. **Hard-rule tests.** A `HardRuleTests` suite asserts the testable AGENTS.md rules this code touches: newer blobs load empty or the default workflow and are never overwritten, and opt-outs either delete or stay on.
4. **Sequence tests for the model manager.** Every sequence of up to three of Download, Cancel, Delete, Load, and Retry runs against fakes. After it settles, these invariants must hold:
   - never two downloads at once;
   - after an accepted Delete with no later Download, no files remain and the state says so;
   - a ready model is on disk.
5. **Mutation check on every fix**, as before, plus a full CI run.

## Constraints

- AGENTS.md hard rules; Swift 6, Swift Testing; `xcodegen` after adding files; `script/ci_test.sh` must pass.
- Merge into the local `main` only; no push or release. Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md`.
- Network access only to the public Hugging Face listing above, anonymously; tests never touch the network.
- Out of scope: the AppState extraction (its own thread), a glossary-learning redesign (waits for the assessment), a frozen preferences value for `PipelineRun`, the folders' dependency on `Settings/`, boundary-script self-tests, hotkey ordering, Codex version check, hosted CI.

## Done when

1. The comparison model becomes ready from the published layout. The tokenizer is fetched into Syrup's model folder, staged with the model, and passed to WhisperKit, so a load never uses the network or `~/Documents`. Someone with the model already downloaded fetches only the tokenizer. Readiness requires each bundle's `coremldata.bin` and `weights/weight.bin`, and the tokenizer.
2. The comparison model download can be cancelled. Remove and turning learning off cancel it, and nothing is moved into place after a cancel. Retry after a failed removal retries the removal.
3. A cancelled or offline load does not mark the model failed.
4. A newer build's `workflowListV3` loads the default workflow; only a corrupt or older one falls back to `workflowListV1`.
5. An accepted Delete always removes the files before a later Download runs.
6. A leftover `history.json` that cannot be deleted at launch is shown in Settings with a retry.
7. A content part with empty text, or a delta holding only labels, is not stream progress.
8. Backups: the round-9 removal on an empty glossary or empty proposals is undone; the newest backup per key is kept, as AGENTS.md says.
9. A model's temperature rejection is remembered for the session, and any rejection body mentioning `temperature` counts.
10. The shared test fixture uses a temporary history folder by default.
11. The Delete-during-load test holds a load that has started.
12. Small items: the audio buffer copy is sized by whole frames; the test script removes its host temporary folder and SwiftPM lock file; the boundary check catches `RunConfiguration.init(`; a staging cleanup failure after a successful move is not a failed download; `.unsupported` stays after a removal; doc fixes.
13. The testing changes above are in place: red-first results recorded, the contract fixture, `HardRuleTests`, and the sequence tests.

## Progress

- 2026-11-14: plan written; AppState thread and glossary-learning assessment started.
- 2026-11-14, red first, against the unfixed code (`c86415a` plus test-only changes and a `waitUntilIdle()` seam):
  - These failed as reported:
    - `aTemperatureRejectionIsRememberedForTheModel`;
    - `aTemperatureRejectionInAnotherShapeIsRetried` (both shapes);
    - `chunksWithoutTextDoNotResetTheInactivityDeadline`;
    - `downloadRightAfterDeleteStartsFromNothing`;
    - `settingsANewerBuildsBlobsLoadEmptyOrAsTheDefaultWorkflowAndAreNeverOverwritten`;
    - `settingsAnUnreadableBlobKeepsItsNewestBackup`;
    - `thePublishedLayoutWithItsTokenizerIsReady`.
  - The sequence test failed on exactly one of 310 cases: a model on disk, then Delete, Download, Cancel, which left "not downloaded" with the model still on disk.
  - These passed as expected: `privacyTurningLearningOffDeletesTheRecordingsOrStaysOn`, `deleteDuringAStartedLoadStillRemovesTheModel`, and `thePublishedLayoutWithoutItsTokenizerIsNotReady`.
- 2026-11-14: all items implemented. Full isolated run: 863 tests in 116 suites passed. `$TMPDIR` leftovers went from 67 host folders and 189 SwiftPM lock files to none.
  - Mutation check, twelve fixes reverted at once.
    - Caught: the tokenizer location, tokenizer-only fetch, removal retry, label-only progress, remembered and any-shape temperature rejections, Delete before Download, the newer-blob default, keeping backups, and the visible history cleanup.
    - Two survived:
      - Retry after a failed load. Another reverted fix in the same run masked it (a full download either way); reverted alone, it fails its test.
      - The audio buffer size. `AVAudioPCMBuffer` reports its byte size from the frame length, and a copy a few bytes too long cannot be observed safely, so that fix is checked by reading and the test says so.
  - Not tested: the cancellation mapping in `WhisperKitBatchTranscriber`, which needs a real WhisperKit load. The coordinator's guard on it is a one-line read check.
  - `script/ci_test.sh` passed on the final tree: boundary check, production build, 863 tests in 116 suites, no source warnings. Committed on `review-round-10` and fast-forwarded the local `main`; not pushed.
