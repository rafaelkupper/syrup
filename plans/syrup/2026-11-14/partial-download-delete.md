# Delete a partial speech-model download

## Goal

A cancelled speech-model download keeps its finished files in staging for the next attempt, and Settings offered no way to delete them while the model shows "Not downloaded". Offer Delete Partial Download there.

## Context

Rafael on 2026-11-14 answered "yes" to whether partial download files should be deletable while a model shows "Not downloaded". Branch `partial-download-delete`, started from `speech-model-statechart` at `2a65b3c` and rebased onto `main` at `6242d61` once step 3 and the new screenshots merged.

## Constraints

- No change to `SpeechModelMachine`; `remove()` already deletes the model folder and its staging folder from any state.
- `loadIfDownloaded()` stays free of disk reads.
- Red first; a deliberate break in each part of the manager fails a test. The button itself has no automated test (no test hosts SwiftUI views); docs/QA.md covers it.

## Done when

1. `SpeechModelManager.hasPartialDownload` is true when the staging folder exists: read at launch and whenever the work drains.
2. In the "Not downloaded" state, Settings shows Delete Partial Download beside Download when it is true, calling `remove()`.
3. Tested: a cancelled download is reported at once and at the next launch, and Delete removes the staging folder and clears the flag.
4. PRODUCT.md, ARCHITECTURE.md, and docs/QA.md describe it; a three-delegate review finds no regression before merge.

## Progress

- 2026-11-14: red first, `aPartialDownloadIsReportedAndDeleteRemovesIt` did not compile without the property. Implemented; the five speech-model suites pass (33 tests). Deliberate breaks: not reading at launch fails the test at the relaunch check; not reading when the work drains fails it after the Cancel.
- 2026-11-14: `script/ci_test.sh` passed: boundary check, production build with no source warnings, 817 tests in 113 suites. Committed on `partial-download-delete`; it is rebased onto `main` after step 3 merges, then reviewed.
- 2026-11-14, review of `ae94c21` (Astra 9, Fable 9, Muse 9; no regression, all safe to merge). Confirmed by running: the flag is right at rest after success, failure, cancel, handover, an unlistable staging folder, and on unsupported Macs; Delete Partial Download removes only this model's folders; `loadIfDownloaded()` gained no disk access (1,000 calls, zero file checks); six breaks of the manager each fail the test. Fixed: the docs now limit the button to the "Not downloaded" state and name the workflow editor's speech-model row, which shows it too; the QA step says the button appears once some files arrived and the cancelled download stopped; this plan's context and test claim. Left as known, harmless limits: an empty staging folder (Canary creates its folders before the first fetch) also shows the button, and deleting it removes the folder; the flag is read when the work drains, so the button appears only after a cancelled download stops, and stays visible while its own removal runs (a second click queues a harmless second removal); a failed Delete Partial Download says "Couldn't remove the model."; a staging folder whose parent cannot be searched reads as absent, as the removal has always skipped such a folder.
- 2026-11-14: docs-only changes after the review; merged into the local `main`, not pushed.
