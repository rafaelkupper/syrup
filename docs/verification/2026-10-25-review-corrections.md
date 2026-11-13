# Review corrections verified on 2026-10-25

Personal identifiers and machine paths in this record use illustrative placeholders.

The five correctness findings and both implementation improvements are fixed locally. Existing cleanup changes were preserved. Verification preceded the user's subsequent authorization to commit and push all pending changes to main. No deployment or production-app restart was requested.

## Changes

- Codex executions use `--ephemeral`, independently of history preferences.
- `AudioBufferSequence` carries capture and forwarding errors through the level tap, recording tee, and transcriber. A late failure prevents delivery. Cancellation and successful draining retain their existing behavior.
- SSE parsing and byte consumption accept LF, CRLF, and CR, including split chunk boundaries and an open transport after `[DONE]`.
- Secret-store operations throw typed errors. Missing files remain valid empty states. Failed reads do not select an environment fallback, and failed deletion does not report success.
- Pause detaches shortcut handlers. Resume restores the current workflow set. Shortcut-editor callbacks reapply the paused state, and ordinary workflow edits leave active registrations intact.
- The glossary pane observes archive count updates after commits, deletions, retention, and scheduled analysis.
- Connection tests use request generations so configuration edits and newer tests invalidate old results.

## Verification

The initial regression run failed on the expected CRLF, credential-deletion, late-audio, and missing-ephemeral cases. It ran 21 tests across two suites and reported five failed tests with seven failed assertions.

The final isolated suite passed all 372 tests across 38 suites. This includes 14 new regression tests, plus stronger assertions in existing tests. Fixtures use temporary directories, isolated preferences, synthetic content, and injected services.

Commands used:

```sh
script/test-isolated.sh
xcodebuild -scheme Syrup -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
xcodebuild -scheme Syrup -configuration Debug -destination 'platform=macOS' build
codesign --verify --deep --strict --verbose=2 /path/to/Syrup.app
```

Both production builds passed. The copied Debug app passed strict recursive signature verification, has bundle identifier `org.syrup.SyrupApp`, and uses the configured Developer ID identity for team `TEAMID1234`. `git diff --check` passed.

The temporary evidence directory is `/tmp/syrup-corrections-20261025.5iGux8/`. It retains the failing and passing test logs, build logs, signature result, task diff, and signed `Syrup.app`. Compiler intermediates were removed after verification.

## Unrun live checks

Live microphone recognition, TCC dialogs, physical hotkeys in other apps, editor paste and typing, and real provider requests were not exercised. The app was not launched or notarized. Use the review correction checks in `docs/QA.md` for those acceptance cases.
