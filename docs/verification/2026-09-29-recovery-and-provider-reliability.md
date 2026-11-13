# Recovery and provider reliability verification

Date: 2026-09-29

## Result

Implemented the five opportunities from the read-only investigation. The full isolated suite passed 360 tests in 38 suites. The production Debug build and `git diff --check` passed.

## Changes

- History retains an optional, nonsecret provider identifier. Ordinary Retry uses that provider with its current configuration. Switching providers is explicit. Legacy records still decode but require a provider choice for Retry; they cannot silently switch through a notification action.
- Selection capture precedes delivery preparation, receives the triggering process identity, validates foreground process and field identity during capture, and returns that field identity for pinned delivery. Source changes abort selection input or omit optional voice context. Accessibility work stays off the main actor.
- Atomic and SSE responses reject `length` and `content_filter` completion reasons. Missing reasons remain compatible. Already typed prefixes retain the existing partial-output warning.
- Preview accepts successful JSON completions without a second request. Atomic fallback applies only to explicit unsupported-stream parameter errors before output. Other HTTP failures and broken streams never automatically retry.
- Clipboard failure retains one completed result in memory. Copy result again performs only a clipboard write and creates success history after successful recovery. Failed revisions retain their prior base; selection input and captured context remain excluded from history.

## Validation

Environment: macOS 27.0, Xcode 26.6. Baseline commit: `238b4ac`.

Initial focused checks passed 161 tests in 6 suites. The final full suite includes additional selection persistence, revision recovery, and cancellation checks.

Commands:

```sh
xcodegen
SYRUP_TEST_ROOT=/tmp/syrup-recovery-fixes-20260929 script/test-isolated.sh
xcodebuild -scheme Syrup -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /tmp/syrup-recovery-production-build build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
git diff --check
```

The isolated app host has no production startup, hotkeys, retention cleanup, or downloads. Provider requests use controlled URLProtocol fixtures at `fixture.invalid`; tests use dedicated UserDefaults suites and disposable history directories. No real microphone, editor, clipboard delivery, or external model was used by the new regression tests.

Regression coverage includes private-provider failure and Retry after workflow edits; explicit provider switching; legacy history decoding; both output paths for incomplete and missing finish reasons; direct typing's partial-output warning; atomic-only preview; narrow unsupported-stream fallback; unrelated HTTP failures and interrupted SSE; repeated clipboard failure and recovery without another request; revision-base preservation; selected-input exclusion from persisted recovery history; capture/delivery ordering; source identity reuse; changed process/field; and cancellation before delivery or during capture.

The prior investigation's full-suite run crashed in an existing audio-feed fixture because it supplied Float32 to AnalyzerInput on this host. That fixture now exercises Float32 capture conversion to an Int16 analyzer-compatible target. Its assertion remains active; production still obtains its format from SpeechAnalyzer. The full suite then passed without skips.

Raw logs are retained at `/tmp/syrup-recovery-focused.log`, `/tmp/syrup-recovery-full.log`, and `/tmp/syrup-recovery-build.log`. Isolated xcresult bundles remain under `/tmp/syrup-recovery-fixes-20260929/test-results/` after build-product cleanup.

## Remaining manual checks

- Real native, browser, and Electron Accessibility fields, including secure fields and slow AX responses.
- Real provider completion reasons and unsupported-stream response formats.
- Live microphone, hotkeys, clipboard restoration, and direct typing.

No performance gain is claimed. The implementation Debug build disabled signing for compile validation. Subsequent signed and notarized 0.6 distribution checks are recorded in `docs/logs/2026-09-29-syrup-0.6.md`. Unrelated local changes were preserved.
