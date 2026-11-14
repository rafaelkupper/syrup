# Delete a partial speech-model download

## Goal

A cancelled speech-model download keeps its finished files in staging for the next attempt, and Settings offered no way to delete them while the model shows "Not downloaded". Offer Delete Partial Download there.

## Context

Rafael on 2026-11-14 answered "yes" to whether partial download files should be deletable while a model shows "Not downloaded". Branch `partial-download-delete`, from `speech-model-statechart` at `2a65b3c` (step 3, awaiting merge).

## Constraints

- No change to `SpeechModelMachine`; `remove()` already deletes the model folder and its staging folder from any state.
- `loadIfDownloaded()` stays free of disk reads.
- Red first; a deliberate break in each part fails a test.

## Done when

1. `SpeechModelManager.hasPartialDownload` is true when the staging folder exists: read at launch and whenever the work drains.
2. In the "Not downloaded" state, Settings shows Delete Partial Download beside Download when it is true, calling `remove()`.
3. Tested: a cancelled download is reported at once and at the next launch, and Delete removes the staging folder and clears the flag.
4. PRODUCT.md, ARCHITECTURE.md, and docs/QA.md describe it; a three-delegate review finds no regression before merge.

## Progress

- 2026-11-14: red first, `aPartialDownloadIsReportedAndDeleteRemovesIt` did not compile without the property. Implemented; the five speech-model suites pass (33 tests). Deliberate breaks: not reading at launch fails the test at the relaunch check; not reading when the work drains fails it after the Cancel.
- 2026-11-14: `script/ci_test.sh` passed: boundary check, production build with no source warnings, 817 tests in 113 suites. Committed on `partial-download-delete`; it is rebased onto `main` after step 3 merges, then reviewed.
