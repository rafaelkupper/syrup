# Speech-model manager as an explicit state machine, checked exhaustively

## Goal

Make `SpeechModelManager`'s decisions a pure state machine (`SpeechModelMachine`) driven by events, and check it with an explorer that runs every interleaving of user actions and asynchronous completions up to a fixed depth. Fix the manager's known state bugs through the machine:

1. Retry after a failed Delete loads or downloads the model instead of deleting it again.
2. Cancel just as a download's files land leaves "Not downloaded" with the model on disk.

Merge into the local `main` only after a three-delegate review of the branch finds no regression.

## Context

- Step 3 of the plan Rafael approved on 2026-11-14 ("OK, do it"). Steps 1 and 2 (`remove-self-learning`) are merged at `e84ed94`.
- Round 11 reviews reproduced both bugs. The existing sequence test (`SpeechModelSequenceTests`) runs up to three actions back to back. It never stops mid-operation and never injects a failure, so it cannot reach either bug.
- Today the manager serializes work by chaining tasks (`lastOperation`) and ignores stale results with a generation counter. The rules live in seven methods and two task closures.
- A third gap is known: a cancelled download keeps its partial files for the next download, and Settings offers no way to delete them while "Not downloaded". Keeping them is deliberate (resume). Whether to offer deleting them is a product decision for Rafael, not part of this step.

## Constraints

- AGENTS.md hard rules; Swift 6 strict concurrency; Swift Testing; `xcodegen` after adding files; `script/ci_test.sh` must pass.
- Behavior stays as it is, except the two fixes. The existing `SpeechModelManagerTests` cases pass without change to the cases themselves.
- The public surface stays: `state`, `download()`, `cancelDownload()`, `replace(_:)`, `retry()`, `loadIfDownloaded()`, `remove()`, `waitUntilIdle()`, `directory`, `stagingDirectory(for:)`.
- `loadIfDownloaded()` runs at every dictation trigger: no new disk access on that path.
- Red first: each bug gets a test on the real manager with held fakes, seen to fail on the current code. The explorer is first run against a machine that reproduces today's logic and must find both bugs.
- The AppState thread (`state-machines` branch) works in `Sources/App/`; this step stays in `Sources/Transcription/` and tests.

## Done when

1. `SpeechModelMachine` holds the state, generation, failure kind, running job, queue, and handover flag. It is a pure function from event to (state, effects), with no I/O.
2. `SpeechModelManager` only interprets: it feeds events into the machine and runs its effects (start a download, load, or removal; cancel the running download; remove the replaced folder).
3. The explorer covers every sequence of user actions (download, cancel, delete, load, retry) and world steps (files land, an operation returns, succeeds, or fails) up to the chosen depth, from a model on disk and from none, with failures injected. At every state it checks:
   - at most one download runs;
   - when nothing is running or queued, "Downloaded" or "Ready" means the model is on disk and "Not downloaded" means it is not;
   - nothing is left "Downloading" or "Loading" when idle;
   - Retry after a failed removal starts only a removal;
   - an unsupported model stays unsupported.
4. Run against today's logic, the explorer reports both bugs; after the fixes it reports none.
5. A conformance test drives the real manager through explorer sequences with held fakes and matches the machine's state after every step.
6. The red-first tests for both bugs pass, and the existing manager test cases pass (their fixture's disk check was corrected; see Progress).
7. A deliberate break in each fix and each invariant check makes a test fail.
8. ARCHITECTURE.md describes the machine; a three-delegate review finds no regression before merge.

## Progress

- 2026-11-14: plan written; branch `speech-model-statechart` from `main` at `e84ed94`.
- 2026-11-14, red first on the current manager (`e84ed94`): `retryAfterAFailedDeleteDeletesAgain` failed (Retry downloaded and loaded the model; the failed removal had already deleted its files but not its folder), and `cancelAsTheFilesLandLeavesAStateThatAgreesWithTheDisk` failed (`notDownloaded` with the model on disk).
- 2026-11-14, explorer against `SpeechModelMachine` written with today's rules: 46 violations from each starting disk. Shortest traces: "model on disk, then delete, failKeepingModel, retry" (Retry started a load); "no model, replacing an older folder, then cancel, land, succeed" (idle, not downloaded, model on disk); and one not reported before, "model on disk, then delete, download, cancel, failKeepingModel" (a Delete that failed after later clicks left `notDownloaded` with the model on disk).
- 2026-11-14, fixes in the machine: Retry after a failed removal removes again; when the queue drains, the machine reads the disk once and moves `notDownloaded` with a model to `downloaded`. (A reverse branch, `downloaded` without a model to `notDownloaded`, was written too and later removed: reviewers showed it could never run.) The explorer then reported no violation: 930 states and 3,948 transitions from no model, 925 and 3,917 from a model on disk.
- 2026-11-14, `SpeechModelManager` became an interpreter of the machine; the public methods are unchanged and `loadIfDownloaded()` reads nothing from disk.
  - `SpeechModelManagerTests`' fixture reported the model on disk from a flag that a Delete never cleared, so three tests failed once the manager read the disk after a Delete. The fake now also requires the model folder, created before the manager reads it, as the real check does. The test cases are unchanged, and the updated file passes all 21 tests against the old manager too.
- 2026-11-14, conformance: replays every explored transition (15,699) on the real manager with a real folder; all match. The first version replayed only one trace per state and missed a manager that ignored the disk on Retry, because Retry and Download after a failed download reach the same state; it now replays every transition.
- 2026-11-14, deliberate breaks, each alone, against the five speech-model suites (27 tests). An earlier run "survived" every break because zsh passed the `-only-testing` filters as one argument and no test ran; the runs below were checked to execute 27 tests.
  - Manager ignores the disk check: caught (regression test, conformance).
  - Manager ignores the handover deletion: caught (conformance and the handover tests).
  - Manager's Retry ignores the disk: caught (conformance, `retryAfterADownloadFailureDownloadsAgain`).
  - Machine's Retry ignores a failed removal: caught (explorer, regression test).
  - Machine never reads the disk when idle: caught (explorer, regression test).
  - Machine skips a stale queued removal: survived at first, because no invariant said an accepted Delete must run. Added "an accepted Delete runs before any later download, and never stays unrun when idle"; now caught by the explorer.
- Open for Rafael: a cancelled download keeps its partial files for the next attempt, and Settings offers no way to delete them while "Not downloaded".
- 2026-11-14: `script/ci_test.sh` passed: boundary check, production build with no source warnings, 811 tests in 113 suites (15.5 s here, from 9.5 s before the conformance test; reviewers measured 19.7 to 29.3 s on shared, loaded machines). Committed; the three-delegate review runs before any merge.
- 2026-11-14, review of `194b18e` (Astra 7, Fable 8, Muse 9):
  - Regression (Astra, Fable): the old manager re-checked a job's generation when its task began, so a load or download made stale by a click before it started was skipped. The rewrite decided only when queuing, so Load then an immediate Delete ran the whole load first (minutes for some models) and Download then an immediate Cancel still downloaded. Neither new test saw it: the explorer treated a queued job as running, and the conformance test let each job reach its fake before the next click. Red first: `deleteRightAfterALoadRequestSkipsTheLoad` and `cancelRightAfterDownloadDownloadsNothing` failed on `194b18e`. Fix: a job's task reports `began`, and the machine skips it if it went stale; the explorer has a `begin` step, and a new invariant says a stale download or load never does its work. The conformance test holds each job's start through `Operations.willBeginJob`, a hook that does nothing in the app.
  - Dead branch and claim (Fable, Muse): the `downloaded` to `notDownloaded` branch of the disk check could not run. Removed, with its sentences in ARCHITECTURE.md and here.
  - Handover not asserted (Fable, Muse): the explorer now checks that the older folder exists exactly while a handover is pending.
  - Progress not covered (Fable): the explorer has a progress step for a running download and checks that a stale download's progress changes nothing; `lateProgressFromACancelledDownloadDoesNotMoveTheNextOne` covers the manager's plumbing.
  - A second Delete accepted while a removal ran was not tracked by the Delete invariant (Fable); a removal newer than the step's starting generation now marks it.
  - Test robustness (Astra, Muse): conformance traces left held fakes and live managers behind; each trace now releases its fakes and drains the manager. A manager that diverged could hang the suite; the fakes now report two operations waiting at once, the idle wait is bounded, and the speech-model suites have a one-minute limit. `waitUntilIdle()` stops if it ever sees a finished task still recorded, as the old manager did.
  - Speed: replaying every transition with the `begin` step took 42 s. The conformance test now expands states with a queue up to one (the manager runs queued jobs the same way at any length; the explorer covers the machine to three), skips progress steps, and drops "model on disk, replacing", which explores the same states as "model on disk". About 1,500 transitions from each of three starting points; the five speech-model suites take about 4.5 s.
  - Deliberate breaks, each alone against the five suites (30 tests), all caught: the manager ignoring the disk check, the handover deletion, the disk on Retry, or `began`; the manager reporting progress with the current generation; the machine's Retry ignoring a failed removal, never reading the disk, skipping a stale queued removal, always performing on `began`, never ending a handover, counting stale progress, or letting progress go back. "Progress goes back" is caught only by `downloadIsExplicitReportsProgressAndLoads`, since the explorer reports one value.
  - Incident: while stopping a stuck mutant run I ran `pkill -f "syrup-tests"`, which also matches other isolated test runs on this Mac, including any the reviewers had going in their own copies.
  - Left as is: the new tests write the model straight into its folder rather than through `SpeechModelCatalog.stagedDownload`, which has its own tests (Muse); routing conformance through it would conflict with the explorer's over-approximation that a cancelled download can still land.
- 2026-11-14: `script/ci_test.sh` passed on the review fixes: boundary check, production build with no source warnings, 814 tests in 113 suites in 9.6 s. Committed; a three-delegate re-check of the fix commit runs before any merge.
- 2026-11-14, re-check of `9aed494` (Astra 7, Fable 9, Muse 9):
  - Regression still open (Astra; Fable as a nit): `began` was checked in one task and the work started in a second, so a click between the two made the job stale and its work still ran (Astra: up to 100 of 100 attempts; none in 2,500 on the old manager). Fix: one task per job, which asks the machine at `began` and starts the work with no suspension in between. Test: `aJobOvertakenAfterItBeganDoesNoWork` runs each case 120 times with fakes on the main actor, clicking after zero to five yields. A first version with fakes off the main actor also failed on the old manager (62 to 86 of 100), because a click can overtake the call while it travels to the fake, after the work was committed to; that race exists in every version and is not this bug. With main-actor fakes: the two-task version fails (16, 17, and 6 of 120), the fix passes 3 of 3 runs, the old manager 2 of 2.
  - Delete tracking inferred from the queue (Astra, Fable, Muse): each Delete, and each Retry after a failed removal, must now queue its own removal, checked from the step; pending Deletes are counted, not flagged. A machine that drops a second Delete while a removal runs is now caught (it passed all 30 tests before). The explorer's counts fell from 1,936 to 1,584 states from no model (1,925 to 1,573 from a model on disk). Without the Delete bookkeeping, the two explorers reach identical sets of machine and disk states; the 352 extra states of the old one were copies of these with its flag cleared while a removal was still pending. (An earlier note here said 89; that came from an incomplete comparison, and Astra and Muse each measured 352.)
  - Handover invariant compared with the machine's own flag (Fable): it now also requires the older folder to be gone after a Delete, after a Cancel that stopped a download, and whenever the state is downloaded, loading, or ready.
  - Dropped conformance start (Muse): `replacingWithTheModelAlreadyOnDiskDeletesTheOlderFolderAtOnce` checks the real manager.
  - Liveness (Muse): the job's task sends `began` even when cancelled, with a comment saying why it must.
  - Doc wording (Muse): conformance replays every transition whose trace has no progress report.
  - Deliberate breaks rerun on the single-task code, against the five suites (31 tests): ignoring the machine's answer at `began`, the disk check, the handover deletion, the disk on Retry, or reporting progress with the current generation; all caught.
- 2026-11-14: `script/ci_test.sh` passed: boundary check, production build with no source warnings, 816 tests in 113 suites in 9.6 s. Committed; a three-delegate re-check of the commit runs before any merge.
- 2026-11-14, re-check of `d6dcd3e` (Astra 9, Muse 9; Fable pending at the time of writing): no regression; the stale-work window is closed at parity with the old manager; a job cancelled before it begins still reports `began`; the new explorer checks catch mutants the old flag invariant missed.
  - The plan's "89" was wrong (both): corrected above.
  - Detection margin (both): the follow-up-load case timed its click from a poll and missed the two-task bug in 3 of 10 of Astra's runs. It now holds the download after it lands and releases it before yielding. Against the two-task version it failed in 5 of 5 runs (14 to 19 of 120 attempts), with the other cases at 14 to 20; the fix passed 3 of 3.
  - The manager's comment now says the call into the operation leaves the main actor and can be overtaken there, as ARCHITECTURE.md already did (Muse).
- 2026-11-14: `script/ci_test.sh` passed on these fixes: boundary check, production build with no source warnings, 816 tests in 113 suites in 9.5 s.
