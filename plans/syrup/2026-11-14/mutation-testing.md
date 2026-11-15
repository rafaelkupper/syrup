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

1. **Generator** (`script/mutation/mutants.py`):
   - reads the changed line ranges from `git diff -U0`;
   - strips comments and string literals from each line before matching;
   - applies one operator at a time:
     - `==`/`!=`;
     - `&&`/`||`;
     - `true`/`false`;
     - flipping the literal in a comparison with a Bool literal (`== false` to `== true`), as the one mutant for that comparison;
     - ` < `/` <= ` and ` > `/` >= ` (spaced only, so generics and arrows are untouched);
     - deleting a line that is a standalone call or assignment statement.
2. **Runner** (`script/mutation-test.sh`): copies the repository to a scratch folder once and builds once with a fixed `SYRUP_TEST_ROOT`. For each mutant it then:
   - applies the mutant;
   - runs the scratch copy's `test-isolated.sh` with a time limit;
   - restores the file;
   - classifies the result from the output.
   It prints survivors as `file:line`, with the original and mutated line.
3. **CI:** `script/ci_test.sh` runs it after the suite passes.
4. **Docs:** ARCHITECTURE.md (Testing) and AGENTS.md's command list. The AGENTS.md change needs Rafael's go, since it is a durable instruction file; ask when it is ready.

## Done when

1. **Generator tests:** offline tests cover each operator, comments and strings left alone, only changed lines used, the deterministic cap, and the equivalent-list match.
2. **Classifier tests:** offline tests cover a build failure, a test failure, a pass, 0 tests executed, and a timeout, each from a real captured log.
3. **Red first, end to end:** with one assertion removed from a test that checks a changed line, the run reports that survivor and fails. With the assertion back, it passes.
4. **Measured:** the time per mutant (incremental build plus suite) and the total on this branch's diff and on step 3's diff. The default cap is chosen from these and recorded here.
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
- 2026-11-14: two classifier rules could hide a survivor by reading an odd run as a catch: a passing summary with a nonzero exit, and `** TEST FAILED **` that names no failing test (a runner that never starts). Both now fail the run (red first). Rechecking every real log then showed the crash log holds a passing summary for the host's last relaunch ("13 tests in 1 suite passed") before `** TEST FAILED **`; the first crash fixture began after that line and hid it. The fixture now starts at the last restart (red first against it), and a run is caught when xcodebuild reports `** TEST FAILED **` and names failing tests, whatever the last summary says. All 26 real logs read as before: 19 step 4 mutants and the test failure killed, the crash killed, the build failure not compiled, the zero-test run unclassified, the three clean runs passed.
- 2026-11-14: `script/ci_test.sh` passed with the mutation steps before the classifier change (14 offline tests; 829 tests; 0 mutants on this branch, which changes no Swift).
- 2026-11-14: `script/ci_test.sh` passed on the final classifier: boundary check, corpus sync check, 16 offline mutation-tool tests, production build with no source warnings, 829 tests in 115 suites, and the mutation step (0 mutants; this branch changes no Swift). Committed on `mutation-testing`; a three-delegate review of this commit and of `fb5f1c6` (the step 4 follow-ups merged after its re-checks) runs before any merge.
