# Restore streamed reasoning progress and remove the self-learning flow

## Goal

1. Fix the one regression of working behavior that round 10 introduced: reasoning sent inside `content` parts no longer resets the stream's inactivity deadline.
2. Remove the self-learning glossary flow: recording dictation audio, the 626 MB Whisper comparison model, the background comparison passes, and the LLM judge.

Keep the manual glossary, quick capture, the proposal list with Add and Dismiss, and MishearingProbe. Merge into the local `main` only after a three-delegate review of this branch finds no regression.

## Context

Branch `remove-self-learning`, from `main` at `3492746`. Rafael on 2026-11-14:
- He approved removing the self-learning flow ("It's ok to remove the self-learning flow").
- On regressions: "it's not ok to create regressions on every pass".
- He approved this order: steps 1 and 2 on one branch, reviewed before merge, then the statechart work ("OK, do it").
- He approved updating AGENTS.md's privacy rule to match, as previewed.

The design assessment behind the removal (2026-11-14) found:
- Whisper large-v3 hears no better than Parakeet Ultra, which Syrup ships: 4.07% against 4.15% WER on 200 Portuguese clips, and far worse on long clips.
- In model-engine runs the pipeline learns from Apple's transcript, not the delivered one.
- It keeps audio on disk.
- No real proposal was ever recorded.

Verified 2026-11-14 from Mistral's reasoning docs (https://docs.mistral.ai/capabilities/reasoning/), on how streamed `delta.content` arrives:
- While thinking, it is a list with a `ThinkChunk`: `{"type":"thinking","thinking":[{"type":"text","text":…}]}`.
- At the transition, one list holds a closing `ThinkChunk` and the first `TextChunk` `{"type":"text","text":…}`.
- For the answer, it is a plain string.

## Constraints

- AGENTS.md hard rules; Swift 6, Swift Testing; `xcodegen` after adding or removing files; `script/ci_test.sh` must pass.
- Smallest change that does the job. No new behavior beyond the regression fix, the removal, and a launch cleanup of the removed flow's files.
- Regression tests are written first and seen to fail on the unfixed code.
- New fixtures come from documented real shapes, with their source named.
- Every claim in docs or this plan is measured as stated.
- The AppState thread (`state-machines` branch) is working in `Sources/App/` in parallel; whichever branch merges second rebases.
- Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md`. No push or release.

## Done when

1. A Mistral thinking chunk counts as stream progress and adds nothing to the answer. At the transition list, only the text chunk's text is answer. Empty text parts and role-only deltas are still not progress. Tested at the parser level from the documented shapes, red first.
2. No code records, stores, or uploads dictation audio. `RecordingArchive`, `RecordingTee`, `WhisperModelManager`, `BatchTranscriber`, `GlossaryLearningCoordinator`, `MishearingJudge`, and the WhisperKit package are gone. So are the `glossaryLearningEnabled` setting and its Settings rows.
3. At launch, Syrup deletes `Application Support/Syrup/Recordings/` and `Application Support/Syrup/WhisperModels/` and the `glossaryLearningEnabled` key. Nothing else is touched. Tested against a temporary folder with siblings that must survive.
4. The proposal list, Add and Dismiss, quick capture, and MishearingProbe work as before; their existing tests pass unchanged.
5. AGENTS.md's privacy rule matches the code (approved text), and ARCHITECTURE.md, PRODUCT.md, IMPLEMENTATION.md, and docs/QA.md no longer describe the removed flow.
6. A three-delegate review of this branch finds no regression before it merges into the local `main`.

## Progress

- 2026-11-14: plan written.
- 2026-11-14, step 1, red first: on the unfixed parser, `mistralThinkingChunksAreProgressButNotAnswerText` failed only on its `progressChunks` expectations, as reported (answer text was already right). After the fix the parser, `StreamingTransformer`, and `OpenAICompatibleTransformer` suites passed: 63 tests in 3 suites.
- 2026-11-14, step 2, removal done:
  - Deleted the seven learning source files, the WhisperKit package, the `glossaryLearningEnabled` setting, `PrivacyOptIns.setGlossaryLearning`, `PipelineRun.learnsFromRecording`, `AppState.recordingArchive` and `recordingWork`, the Glossary learning section, the Privacy recordings row, and `AppSettings.addGlossaryProposals` (its only caller was the coordinator).
  - Added `RetiredGlossaryLearning.removeLeftovers()`, run at every launch off the main actor, and a boundary check that fails on any audio file API in `Sources/`. A planted `AVAudioFile(forWriting:)` failed the check; the same name in a comment or string did not.
  - Tests whose subject was removed were deleted: the six learning suites; `quittingWaitsForACancelledRecordingToBeDiscarded` and `oldFailureCleanupMustNotOverwriteNewRun` (both held an archive discard that no longer exists; the quit wait they also covered is tested again below); `listingPendingMustPreserveActiveWAV`; the learning hard-rule, copy, and opt-out tests. `storedProposalsAndDismissalsAreCapped` moved unchanged to `GlossaryTests`.
  - Tests that used the archive only as a probe keep their other checks: the short tap now waits on the recorder start; the Parakeet tests keep "cancel stops Apple" and "a model run delivers its own transcript whether Apple succeeds or fails"; `audioStagesPreserveUpstreamFailure` checks the level tap alone; the attach test checks that a history opt-out works once attached.
  - Full isolated run: 796 tests in 109 suites passed (863 in 116 before the removal).
  - Mutation check on the cleanup, each mutant alone: removing only `Recordings`, deleting the whole support folder, and keeping the key were caught. Stopping at the first absent folder (`break` for `continue`) survived, because every fixture had both folders. Added `eitherFolderAloneIsRemoved`; the mutant is now caught.
  - Not testable in the unit host: the launch call in `SyrupApp` (the test host is inert). Covered by a manual check in docs/QA.md.
  - Not cleaned: a tokenizer that builds before round 10 may have left in `~/Documents/huggingface`. That folder is Hugging Face's shared cache, outside Syrup's folder, and touching `~/Documents` would raise a Files and Folders prompt.
- 2026-11-14: `script/ci_test.sh` passed: boundary check, production build with no source warnings, 798 tests in 109 suites. Committed on `remove-self-learning`; the three-delegate review runs before any merge.
- 2026-11-14, review of `a3dec87` (Astra 8, Fable 8.5, Muse 8; no behavior regression in the retained pipeline; full suite passed for each). Fixed:
  - Silent cleanup failure (Astra: regression of the old leftover disclosure). `removeLeftovers` returns the folders still on disk, and Privacy lists them under "Files from glossary learning" with Show in Finder and Delete Now. Tested by `aFolderThatCannotBeDeletedGoesAtTheNextLaunch`; a mutant returning nothing is caught.
  - Quit coverage (all three). `quittingWaitsForACancelledRunToUnwind` holds a run whose transcriber ignores cancellation; `quittingWaitsForTheVolumeRestore` holds the restore write. Dropping run tasks or the volume work from the quit wait was caught in 3 of 3 runs each.
  - Parser over-breadth (Muse). Text parts again count only by their text, as in round 10; a part without a `text` string, such as Mistral's thinking chunk, counts by what it carries. Red first: text parts with empty text plus `id` or `format` counted as progress on `a3dec87`; they do not now. Removing the thinking-part clause fails the Mistral test.
  - Apple's early cancel (Fable, pre-existing gap on a line this branch changed). `appleStopsAsSoonAsTheModelTranscriptExists` holds the transformation; removing the cancel fails it.
  - Docs: the recording tee and "recording analysis" (ARCHITECTURE, QA), the parser rule (ARCHITECTURE twice), the Privacy row (ARCHITECTURE, QA), and the Mistral test comment, which now says the fixture follows the docs' prose because the page prints no streamed JSON.
  - Leftovers: the unused `work` parameter of `openMicrophone`, `FakeRecorder.finishesStreamOnStop`, and the cleanup's default folder now uses the injected file manager.
  - README screenshots: superseded by the re-check below.
  - Left as is: "retention cleanup" in AGENTS.md, ARCHITECTURE.md, and `SyrupApp.swift` (still true for the history cleanup and this one; AGENTS.md needs a request); "Suggested from your recordings" (the remaining proposals did come from recordings); `addGlossaryProposal` with only test callers; numbers and flags counting as progress (step 4); the five-name audio boundary list.
- 2026-11-14: `script/ci_test.sh` passed on the fixes: boundary check, production build with no source warnings, 801 tests in 109 suites. Committed; a three-delegate re-check of the fix commit runs before any merge.
- 2026-11-14, re-check of `65276e2` (Astra 8, Fable 8.5, Muse 8.5; no behavior regression; every claimed fix failed its test when removed; quit tests passed 10 of 10 and 5 of 5 repeats). Fixed:
  - A support folder that cannot be searched hid the leftovers (Astra, Muse): `fileExists` said no. Now a folder counts as missing only when the system says so (`ENOENT`, `ENOTDIR`); anything else is reported. Red first: `foldersThatCannotBeInspectedAreReported` failed on `65276e2`.
  - Paths had a trailing slash, so a dangling symbolic link in a folder's place was followed and skipped. Now the link itself is reported and removed and its target kept (`aLinkInAFoldersPlaceIsRemovedAndItsTargetKept`, which failed before the slash was removed).
  - The Privacy row names only what is left (`RetiredLearningCopyTests`), and waits for the launch cleanup (`RetiredGlossaryLearning.launchCleanup`) before reading, so a deletion still under way is not shown as failed (Fable, Muse).
  - ARCHITECTURE still said a run files its recording and quit waits for recordings (Muse); fixed, and the cleanup paragraph describes the inspection rule and link handling.
  - README screenshots (all three): painting the Learning section over was not faithful, because the Glossary pane has a fixed height and "Built-in vocabulary" moves up into that space. A real view rendered offscreen at 2x with the same data lines up with the capture exactly (offset 112, 252), but its text draws lighter, with or without font smoothing, so pasting it in would look patched. The screenshots are now the original capture cropped below the voice-check footer, joined to the original window bottom where its edges are still straight (seam difference at most 3 levels out of 255). Every pixel is real current UI, but the real window is taller and shows Built-in vocabulary below that point. A fresh capture is the faithful fix.
  - Left as is: parser edge cases with no documented provider shape (a part with no `text` but labels, a `{"type":"reasoning","text":…}` part read as answer, `text: null` with an `id`), all counted the same on `a3dec87` and belong to step 4; the Privacy row not refreshing after a deletion in Finder until the pane reappears.
- 2026-11-14: `script/ci_test.sh` passed on the re-check fixes: boundary check, production build with no source warnings, 804 tests in 110 suites. Committed; a final three-delegate re-check of this commit runs before any merge.
