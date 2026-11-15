# Mutation testing of changed lines in `script/ci_test.sh`

## Goal

`script/ci_test.sh` fails when a branch changes a line of app code that no test checks. It makes small deliberate breaks (mutants) in the Swift lines the branch changed, runs the suite against each one, and reports every mutant the suite still passes (a survivor). Today these breaks are made by hand, once per review round. Three of those manual runs went wrong:

- one tested nothing (zsh passed the test filters as one argument, so 0 tests ran);
- one missed a whole category (the conformance test replayed one trace per state);
- one was never run (Fable's surviving remember-before-decode mutant).

## Context

- Step 5 of the plan Rafael approved on 2026-11-14 ("OK, do it"). Steps 1 to 3 and the partial-download Delete are merged into the local `main`. Step 4 is merged once its re-check passes.
- There is no CI server. `script/ci_test.sh` is what a developer or agent runs before a review: the boundary check, the corpus sync check, xcodegen, the production build, then `script/test-isolated.sh`.
- `script/test-isolated.sh` copies `Sources/` and `Tests/` into a new temporary folder and builds there from scratch, so each run is a full build. With `SYRUP_TEST_ROOT` set it reuses one folder, and rsync copies only changed files, so the build is incremental.
- The full suite is 829 tests and runs in about 10 seconds once built.
- No mutation tool is installed. Muter needs Homebrew or Mint, mutates whole files, and its support for Swift Testing under `xcodebuild` is unverified.
- The repository's own scripts are shell and Python 3 (`script/release.py` and its `unittest` tests), with no third-party packages.

## Constraints

- Never mutate the developer's checkout. Mutants are applied in a scratch copy, which is removed afterwards, including on interrupt.
- Mutate only the Swift lines under `Sources/` that the branch changed: the diff against the merge base with `main`, plus uncommitted changes. Skip comments and string literals. On `main` with nothing changed, report that and pass.
- Classify each mutant from the run's own output:
  - **killed:** a test failed;
  - **survived:** tests ran and all passed;
  - **did not compile:** not counted either way;
  - **timed out:** counted as killed, and listed.
  A run that executed 0 tests is an error, never a survivor.
- Survivors fail the run. A mutant that cannot change behavior (an equivalent mutant) is listed in a checked-in file with a reason, matched by file, original line text, mutated line text, and which line with that text it is (counting from the top). Line numbers shift and are not used.
- Bounded time: the number of mutants is capped (default and override to be set from measurements). The selection is deterministic, so a rerun makes the same mutants. A cap that drops mutants says how many were dropped.
- No new dependencies. The generator and classifier have their own offline tests on fixture snippets and fake logs.
- AGENTS.md hard rules hold: the mutation run writes no user content and no secrets, and its logs hold only build and test output.

## Approach

1. **Generator** (in `script/mutation.py`):
   - reads the changed line ranges from `git diff -U0`;
   - strips comments and string literals from each line before matching;
   - applies one operator at a time:
     - `==`/`!=`;
     - `&&`/`||`;
     - `true`/`false`;
     - flipping the literal in a comparison with a Bool literal (`== false` to `== true`), as the one mutant for that comparison;
     - ` < `/` <= ` and ` > `/` >= ` (spaced only, so generics and arrows are untouched);
     - deleting a line that is a standalone call or assignment statement.
2. **Runner** (in `script/mutation.py`): copies the repository to a scratch folder once and builds once with a fixed `SYRUP_TEST_ROOT`. For each mutant it then:
   - applies the mutant;
   - runs the scratch copy's `test-isolated.sh` with a time limit;
   - restores the file;
   - classifies the result from the output.
   It prints survivors as `file:line`, with the original and mutated line.
3. **CI:** `script/ci_test.sh` runs it after the suite passes.
4. **Docs:** ARCHITECTURE.md (Testing) and AGENTS.md's command list. The AGENTS.md change needs Rafael's go, since it is a durable instruction file; ask when it is ready.

## Done when

1. **Generator tests:** offline tests cover each operator, comments and strings left alone, only changed lines used, the deterministic cap, and the equivalent-list match.
2. **Classifier tests:** offline tests cover a build failure, a test failure, a crash, a pass, and 0 tests executed, each from a real captured log, and a time-out, from a fake run whose child ignores SIGTERM; the whole process group must stop.
3. **Red first, end to end:** with one assertion removed from a test that checks a changed line, the run reports that survivor and fails. With the assertion back, it passes.
4. **Measured:** the time per mutant (incremental build plus suite) and the total on step 4's diff (the only Swift diff the tool can run against without rewinding the tree); step 3's total is estimated from its mutant count. The default cap is chosen from these and recorded here.
5. **CI and docs:** `script/ci_test.sh` passes with the mutation step on a branch, and ARCHITECTURE.md describes it.
6. **Review:** a three-delegate review finds no regression before merge.

## Progress

- 2026-11-14: plan written while the step 4 re-check runs. Measurements wait until the reviewers' test runs finish, so timings are not skewed by their builds.
- 2026-11-14: generator, classifier, and runner written (`script/mutation.py`), with 13 offline tests (`script/test_mutation.py`). Options: `--base`, `--limit` (or `SYRUP_MUTANTS`), `--only path:line` to rerun one survivor, `--list`, `--logs`.
- 2026-11-14, real runs captured in a scratch copy (fixtures in `script/mutation-fixtures/`, local paths removed). A compile error under `xcodebuild test` prints `** TEST FAILED **` and "Testing cancelled because the build failed.", not `** BUILD FAILED **`, so the first classifier counted every mutant that does not compile as killed. Red first against the real log; now read from the build's own words. A crash restarts the test host and ends in `** TEST FAILED **` with no Swift Testing summary (killed). A filter that matches nothing prints no summary and exits 0 (unclassified, which fails the run).
- 2026-11-14, measured in that scratch copy: full build and suite 59 s; rerun with nothing changed 14 s; one mutant (incremental build plus the 829-test suite) 22 s; restoring 16 s; a crashing mutant 79 s (the host restarts). Mutants per earlier diff: steps 1 and 2, 53; step 3, 81; partial-download Delete, 6; step 4, 19. Default limit 20: about 60 s plus 8 minutes on a branch that changes Swift, nothing on one that does not. Before a review, a full run uses `SYRUP_MUTANTS=200`.
- 2026-11-14, the whole step 4 diff (`--base f57d9e7`, 19 mutants): all killed, 22 s each, 8 minutes in all. Three mutants in the non-streamed remember path (lines 279, 285, 286) are killed only by the `streamed: false` cases of `aRejectionIsRememberedByTheParameterItBlames`.
- 2026-11-14, red first end to end: with that test limited to `streamed: true`, `--only ...OpenAICompatibleTransformer.swift:286` reports the deleted `Self.rememberTemperatureRejection(for: temperatureKey)` as a survivor and exits 1; unweakened, the same mutant is killed (the run above). The test file was restored and checked against git.
- 2026-11-14: listing that survivor as equivalent also silenced line 216, the same text in the streamed path, which behaves differently. Red first (`test_an_entry_names_which_of_identical_lines_it_means`); an entry now names which line with that text it is, and the run prints a ready entry for each survivor. Rechecked: an entry for occurrence 2 skips line 286 and leaves 216 running.
- 2026-11-14: two classifier rules could hide a survivor by reading an odd run as a catch: a passing summary with a nonzero exit, and `** TEST FAILED **` that names no failing test (a runner that never starts). Both now fail the run (red first). Rechecking every real log then showed the crash log holds a passing summary for the host's last relaunch ("13 tests in 1 suite passed") before `** TEST FAILED **`; the first crash fixture began after that line and hid it. The fixture now starts at the last restart (red first against it), and a run is caught when xcodebuild reports `** TEST FAILED **` and names failing tests, whatever the last summary says. All the real logs then kept read as before: 19 step 4 mutants and the test failure killed, the crash killed, the build failure not compiled, the zero-test run unclassified, the three clean runs passed (26 of the 27 kept; the capture baseline was not replayed then; all 27 were replayed in review).
- 2026-11-14: `script/ci_test.sh` passed with the mutation steps before the classifier change (14 offline tests; 829 tests; 0 mutants on this branch, which changes no Swift).
- 2026-11-14: `script/ci_test.sh` passed on the final classifier: boundary check, corpus sync check, 16 offline mutation-tool tests, production build with no source warnings, 829 tests in 115 suites, and the mutation step (0 mutants; this branch changes no Swift). Committed on `mutation-testing`; a three-delegate review of this commit and of `fb5f1c6` (the step 4 follow-ups merged after its re-checks) runs before any merge.
- 2026-11-14, review of `fa2b08a`, Astra (6, not safe to merge; `fb5f1c6` 9, safe): five false passes or cleanup gaps, all reproduced; each fixed with a test seen to fail on the old code first:
  - **Changed lines lost:** file names were read from the diff's `+++ b/` lines. With `diff.noprefix` or `diff.mnemonicPrefix` set, every file was dropped. A name with a space was read with a trailing tab, and a non-ASCII name was quoted and dropped. All three gave zero mutants and a pass. File names now come from `git diff --name-only -z --no-renames`, and each file's hunks from its own diff with a literal pathspec.
  - **Bool literals:** a literal after `= ` was never flipped (`let enabled = true`); only a literal compared with `==` or `!=` is now left to its single comparison mutant.
  - **Time-out cleanup:** a time-out stopped once the group's leader exited, leaving a child that ignored SIGTERM running against the reused build folder. It now waits for the whole group and then sends SIGKILL.
  - **Binary files:** an untracked binary file under `Sources/` crashed discovery; names are now filtered to `.swift` before any file is read.
  - **Scratch cleanup:** a `--logs` path naming a file left the scratch copy behind. It is now refused before anything runs, and the scratch copy is removed even if copying the logs fails.
  - Also: a limit below 1 is refused (it passed with mutants pending); a checkout without a local `main` gets a message instead of a traceback; "runs a whole branch" now says "up to 200"; a renamed file counts whole.
- 2026-11-14: with Bool literals after `= ` now flipped, step 4's diff has 21 mutants. The two new ones set `var rejectionNamedTemperature = false` to `true` (lines 186 and 270); both survived a real run (16 s each). They are equivalent: the flag is read only when temperature is left out, which before any retry means this endpoint and model are already remembered, so remembering again inserts a key already in the set, and a retry assigns the flag before reading it. Listed in `script/mutation-equivalent.json` by occurrence 1 and 2 with that reason, the first entries; the run now reports 2 listed and 19 run.
- 2026-11-14, review of `fa2b08a`, Muse (7, not yet safe; `fb5f1c6` safe). Its quoted-path, missing-`main`, and time-out-test findings are the fixes after Astra's review. Also fixed, each with a test seen to fail first:
  - **Interrupt cleanup.** An interrupt left compilers running and the scratch copy behind (50 MB in Muse's run). A real run showed why: Xcode's build service starts each compiler in its own process group, so stopping the run's group cannot reach them. Stopping a run now also stops every process naming the run's own temporary build folder, waits for all of them, then sends SIGKILL. A fake compiler that leaves the group and ignores SIGTERM is now stopped. SIGINT always interrupts, even when inherited as ignored by a background job. Rechecked on real runs: SIGINT mid-build, with 13 build processes in the scratch copy, exited in 1 s with none left and the scratch removed; SIGTERM did the same.
  - **`--only` typos.** An `--only` naming a line with no mutant passed as "0 run"; it is now refused.
  - **Entries moving to another line.** Inserting an identical line above moved an entry onto another line. Entries now also name the code lines just before and after, so a change there makes the entry stop matching rather than move.
  - **Selection reshuffles.** The selection hash included the line number, so a line inserted elsewhere reshuffled which 20 ran. It now uses the text and neighboring lines.
  - **Statement deletions that cannot compile.** Deleting a line that opens a block (`x = Task {`) could never compile; a deletion now needs (), [], and {} closed on the line.
  - **SwiftUI views.** View bodies would always survive, since no test hosts a view; lines inside a type that conforms to `View` are skipped and counted. Files that import SwiftUI are still mutated outside view types; they hold tested logic such as `RecordingCueController` and `AppState` extensions.
  - The merge base falls back to `origin/main`.
  - ARCHITECTURE.md now names what is not checked (deleted-only lines, lines no operator applies to, view lines) and the 9-minute cost.
  - Known limit, noted: a Swift regex literal containing a quote would confuse the masking; `Sources/` has none.
- 2026-11-14, review of `fa2b08a`, Fable (7, safe to merge, fix the false passes first; `fb5f1c6` 9.5). Its diff-header, Bool, `--only`, SwiftUI, binary-file, missing-`main`, `--logs`, entry-drift, and generator findings are the fixes after Astra's and Muse's reviews. Also fixed, each with a test seen to fail first:
  - **Failed builds counted as "did not compile".** A failed build counted so whatever failed, so a run whose every mutant failed to build for an outside reason (disk, signing, a package fetch) passed. It now counts only when the compiler names the mutated file (`.../Sources/X.swift:8:36: error:`); any other failed build fails the run. The build-failure fixture now includes those error lines.
  - **`#"""#` blanked the rest of the file.** It was read as opening a multi-line string. `"""` now opens one only when the line ends after it. This occurs in Tests, not in `Sources/`.
  - **Stale entries.** An entry matching no line of its file as it is now, or naming a file that is gone, was ignored. It now fails the run until it is updated or removed.
  - **Locale encoding.** Files were read and written in the locale's encoding, which crashes under US-ASCII. Every read and write now names UTF-8, and a test checks every `open`, `read_text`, and `write_text` call in the tool.
  - **`SYRUP_MUTANTS`.** An empty value was a traceback and is now the default. A non-number is refused.
  - **Prefix `!`.** It was never mutated (47 lines); removing it is now an operator.
  - **SIGHUP.** It left the build running and the scratch copy behind; it now stops the run like SIGTERM.
  - **SwiftPM lock files.** They were left in `$TMPDIR`: four per mutation run. `test-isolated.sh` also matched only the `Package.resolved` one of its own four, so 393 earlier test runs had left 1,179. The tool now removes its own, and `test-isolated.sh` matches all four kinds, for its own run and for earlier runs whose copy is gone.
  - **Orphaned host preference files.** Back-to-back runs removed a run's marker before cfprefsd's late save, so its host domain was never deleted; four such files were in `~/Library/Preferences`. `test-isolated.sh` now deletes a host domain once ten minutes old unless its run is live.
  - The header lines are flushed, so piped output shows progress.
  - **Claims.** Done-when 4 now says step 3's total is estimated from its count (81 mutants, about 30 minutes), since the tool runs against the working tree; the log count is corrected to 27.
- 2026-11-14, final code on the partial-download diff (`--base ae94c21~1`; 25 mutants, 2 listed as equivalent, 23 run, 10 changed view lines skipped): 20 killed, 1 did not compile, 2 survived, a real gap in merged code. In `SpeechModelManager`, `path(percentEncoded: false)` changed to `true` in both partial-download checks (lines 56 and 146) passed every test. The real storage folder is under `~/Library/Application Support`, whose space a percent-encoded path would turn into `%20`, so the check would never find the files and Delete Partial Download would never show. The test used a temporary folder with no space. `aPartialDownloadIsReportedAndDeleteRemovesIt` now lays its folder out as the real one, under "Application Support"; both mutants are now killed, and the suite passes. Step 4's diff on the final code: the same 21 mutants (no prefix `!`), 19 killed in the run before, 2 equivalent.
- 2026-11-14: `script/ci_test.sh` passed on the review fixes: boundary check, corpus sync check, 33 offline mutation-tool tests, production build with no source warnings, 829 tests in 115 suites, mutation step (0 mutants; this branch changes no Swift under `Sources/`). The test runs after the `test-isolated.sh` change removed the 1,179 old lock files and the 4 orphaned host domains; none are left. SIGHUP on a real run: exit 129 in 1 s, no process left, scratch removed. Committed; a three-delegate re-check runs before any merge.
