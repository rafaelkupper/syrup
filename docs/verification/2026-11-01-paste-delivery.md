# Paste delivery verification

Personal identifiers and machine paths in this record use illustrative placeholders.

**Update after review.** The per-bundle cache was removed because an in-place browser update does not change the `.app` modification date. An uncached scan measured a median of 0.06 to 0.07 ms on Chrome and 0.14 to 0.15 ms on Xcode, over three runs of 500 scans each. Figures below that mention caching predate this change.

The paste group keeps clipboard delivery atomic and adds Shift-Return line breaks, layout-aware Command-V, and typed delivery for Chromium 155 and 156. No real input events were posted, no installed app was launched, and the user's clipboard was not accessed.

## Automated checks

All commands used `SYRUP_TEST_ROOT=/tmp/syrup-paste-tests script/test-isolated.sh`. The script builds an inert app with the separate `org.syrup.SyrupIsolatedTests` identity.

| Run | Extra arguments | Result |
| --- | --- | --- |
| Line breaks | `-only-testing:SyrupTests/StreamingTypistTests -only-testing:SyrupTests/ReviewImprovementTests` | 26 tests in 2 suites passed |
| Layout | `-only-testing:SyrupTests/AutoPasterTests -only-testing:SyrupTests/PasteKeyResolverTests` | 8 tests in 2 suites passed |
| Typed delivery | `-only-testing:SyrupTests/PasteStrategyTests -only-testing:SyrupTests/AutoPasterTests -only-testing:SyrupTests/StreamingTypistTests -only-testing:SyrupTests/AppStateTests` | 124 tests in 4 suites passed |
| Full suite | None | 387 tests in 40 suites passed |

Logs are `/tmp/syrup-paste-step1.log`, `/tmp/syrup-paste-step2.log`, `/tmp/syrup-paste-step3.log`, and `/tmp/syrup-paste-full.log`.

The focused layout build initially rejected an unannotated closure receiving a main-actor function. Its closure type now preserves the actor. The first strategy run exposed stale URL resource metadata preventing cache invalidation; reading current file attributes fixed it. Two initial quoted-output assertions assumed the fake transformer normalized text; the corrected fixture instead asserts that finalized quotes survive typed delivery unchanged. A later focused run exposed the existing cancellation test's single-yield race. It now waits for the text-posted callback before cancelling. All final runs above passed.

Xcode reported unavailable iOS Simulator support and skipped AppIntents metadata extraction. These did not prevent the macOS tests. No tests were intentionally skipped.

## Current-layout cost

The throwaway `/tmp/syrup-paste-key-probe.swift` compiles the production `PasteKeyResolver.swift` with `swiftc -parse-as-library -O`. Timing includes obtaining the current input source, generating the Command-layer map, and resolving the V key. Every result is counted. It does not post events or switch the input source.

Six independent processes made 1,000 calls each. All 6,000 calls returned key code 9. Per-process median milliseconds were 0.015958, 0.015333, 0.016083, 0.015750, 0.015708, and 0.016375. Per-process p95 ranged from 0.016791 to 0.036042 ms. The sixth probe recorded its first call at 56.682916 ms, also its maximum. The first five process maxima ranged from 30.286250 to 42.176834 ms.

A separate throwaway `/tmp/syrup-tis-startup-probe.swift` timed the first TIS input-source read at 151.459584 ms under concurrent system activity. The full resolver immediately afterward took 0.185875 ms. This isolates a substantial process-initialization cost in the platform input-source lookup. A cache keyed by input-source ID would still need that initial lookup. Repeated resolution is below the requested approximately 1 ms threshold, so no layout cache was added.

The Mac had 14 logical CPUs and load averages of 20.03, 15.14, and 14.76 when the first measurements started. File operations and builds were active. These are resolver cost measurements, not a translation speedup or real-event end-to-end latency claim.

## Chromium bundle check

A local Chromium 156 bundle was inspected without launching it. Its framework contained multiple version directories and a `Current` link. The production resolver selected `typeText`. Fake bundle tests also cover 155, 157, `Versions/A`, malformed version names, version files, a staged second version, independent bundles, and cache invalidation after a bundle modification.

The reported Chromium 155/156 race and fix in 157 were not reproduced with system input or independently corroborated; the claim remains externally unverified here.

## Review and remaining checks

The CRLF test asserts delivered text instead of intermediate chunk boundaries. No compatibility shim, content logging, or unrelated application refactor was added. The Chromium removal-condition comment remains.

Still unverified are Shift-Return behavior in real chat editors, real Dvorak/Colemak/Dvorak-QWERTY-Command shortcuts, real secure-input and field-focus transitions, third-party autocorrect, and the Chromium synthetic-paste race. The task explicitly prohibited the real events needed to verify these. There are no open implementation questions.
