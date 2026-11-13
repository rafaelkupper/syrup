# Dictation follow-up verification

Personal identifiers and machine paths in this record use illustrative placeholders.

The final repair acceptance and ZIP breakdown below supersede earlier signing and test limitations. Earlier sections retain the original implementation evidence.

## Boundaries

Base is `78b2b47`. All app tests use `script/test-isolated.sh` and bundle ID `org.syrup.SyrupIsolatedTests`. No installed app, production bundle launch, real microphone, real input events, user clipboard, or Application Support cleanup was used. No push, publication, release creation, or notarization was performed.

## Sparkle

Sparkle 2.10.1 is pinned in `project.yml`. `generate_keys -p` reported no existing key, then `generate_keys` created the default `ed25519` signing key in the login Keychain. The private key was never printed, exported, or stored in source. The public key is `<publisher-public-key>`.

The isolated run reported 479 tests in 54 suites: 476 passed and 3 skipped. The inert host loaded the embedded framework with ad-hoc signing and hardened runtime disabled. The universal unsigned Release build passed with `ARCHS=arm64 x86_64`, `ONLY_ACTIVE_ARCH=NO`, `CODE_SIGNING_ALLOWED=NO`, and `CODE_SIGNING_REQUIRED=NO`. `lipo -archs` confirmed both slices in the app and embedded Sparkle framework. The built Info.plist contains the feed, public key, disabled system profiling, and disabled automatic downloads. Custom `INFOPLIST_KEY_*` values were omitted by Xcode, so the manifest now generates an explicit plist. The first compile needed an explicit main-actor protocol conformance.

A throwaway ZIP of the unsigned Release app was processed by Sparkle's `generate_appcast`. `script/verify-update.swift` verified the enclosure length and EdDSA signature using only the manifest's public key. The test feed uses `example.invalid`. No update was downloaded or installed. Real Developer ID nested-helper signing, notarization, publication, scheduled reminder behavior, and update between installed builds remain unverified.

The release CLI's help and Python syntax checks passed. Manifest and feed parsing checks passed for the empty live feed and both Sparkle build-version encodings. Release preparation and `--publish` were not run. `docs/RELEASE.md` remains untouched and needs a pointer to `docs/UPDATES.md`.

No lint suppressions were added.

## Inert launch and ZIP measurement

Baseline `78b2b47` and the Sparkle candidate, before the final observation refinements, were built universal Release with the same package cache, signing disabled at build, and no archive stripping. The production `SyrupApp` constructor remains reachable behind an argument never passed. A separate main exits at `applicationDidFinishLaunching`. Both have the isolated bundle ID and were signed ad-hoc before measurement. There is no updater initialization or network in the timed region. The clock covers process spawn through successful exit.

Six newly signed copies per side were launched twice each, alternating build order. Ten repeated launches per side also alternated. All 44 exits succeeded. First-copy launches were baseline median 789.4 ms, range 777.9 to 874.7 ms, and Sparkle 804.3 ms, range 789.6 to 807.4 ms. Second launches were 139.5 ms (135.3 to 151.6) and 148.7 ms (141.5 to 164.6). Repeated launches were 139.1 ms (126.9 to 783.9) and 140.3 ms (130.7 to 810.1). Each gap is smaller than the observed spread. No measurable difference was established. The universal inert ZIPs were 32,714,996 and 33,759,540 bytes, a 1,044,544-byte increase. These unstripped ZIP sizes are not release-download estimates.

Load averages were 12.47, 11.95, and 10.26 on 14 logical CPUs. No unrelated process was stopped. A separate sample of a slow isolated test-host startup showed dyld loading dependencies blocked in file open, before app code. This is evidence of loader and filesystem cost, but does not isolate the causal cost of Sparkle. Full production initialization, Gatekeeper download checks, installed update transitions, and a cold launch after reboot remain unmeasured. Scratch sources, build logs, JSON timings, and summary are under `.cache/follow-ups/` in this worktree.

## Corrections and test-environment limitation

Corrections passed their pure matching, canonical Unicode, overlap, literal-output, old-settings decoding, and pipeline snapshot tests. Initial full runs reported 485 tests in 55 suites: 482 passed and 3 skipped. A subsequent run stalled in dyld before tests; it was terminated and retried with split Debug dylibs disabled, then from a fresh local host. The local full suite reported 485 tests and failed with 20 issues in `OutputDuckerTests` and `OutputDuckingTests`. A repeat failed with 18 issues in those same suites. All correction tests passed.

These failures are an environment limitation. A standalone `swift -e` using a new unique `UserDefaults` suite also returned `synchronize false`, outside Syrup. The test host reports `Path not accessible` for synthetic preference domains. Explicit task-owned preference directories did not change this. No preferences daemon, permission, real volume, or durable test body was changed. Later checks retain a full-suite run and separately exclude only these two suites so other behavior can be validated. The local fixture root was `/tmp/syrup-followups-tests-bc9a9828`. Task-created temporary roots were removed after final acceptance; full and available `.xcresult` bundles are preserved under `.cache/follow-ups/results/`.

The optional common-word warning was omitted because there is no locale-aware common-word list in the app; a short English-only list would give misleading assurance.

## Paste Last

463 tests passed and 3 skipped in 53 suites, with the 21 tests in `OutputDuckerTests` and `OutputDuckingTests` explicitly excluded for the independently reproduced preferences failure. Four strategy/trust combinations verify clipboard recovery, existing notices, history preservation, and active-run rejection. A controlled sleeper verifies that starting a new run during the delay posts no input. No real input or clipboard was used.

## Spoken symbols

464 tests passed and 3 skipped in 54 suites, with the same 21 preference-dependent tests excluded. Coverage includes all English and Portuguese symbols, model punctuation, repeated and adjacent symbols, quotes and line breaks, accented and combining-mark boundaries, false-positive words, and unsupported locales. An initial two-case failure exposed synthetic separator spaces being protected along with punctuation; the final builder protects only the emitted symbol. No translation-path call was added.

## Smart spacing

468 tests passed and 3 skipped in 55 suites, with the same 21 preference-dependent tests excluded. Tests cover default-off behavior, zero reads when off or copy-only, word and Unicode classification, both atomic strategies, exact clipboard content, one streaming prefix, and timeout fallback. No real editor, caret, or synthesized input was used. Supplementary characters that cannot fit the one-unit query use the unspaced fallback.

An optimized standalone probe compiled the actual `DeliveryTarget` and timeout code with `swiftc -O -swift-version 6`. Five trials of 1,000 successful injected reads each measured a median read-phase overhead of 16.49 microseconds, with trial averages from 13.38 to 17.19 microseconds. All 5,000 reads executed and returned the expected boolean. Five injected stalled reads returned the unspaced fallback after a median 100.88 ms, range 100.28 to 104.24 ms, including scheduling beyond the 100 ms deadline. Load averages were 7.15, 15.02, and 15.90. Task and timer scheduling dominate this synthetic probe; it does not time another app's AX implementation, additional input events, or end-to-end delivery. Real opt-in delivery latency therefore remains unmeasured. With the toggle off there is no new AX read, timer, or revalidation. The helper and raw timings are `.cache/follow-ups/SpacingProbe.swift` and `spacing-times.txt`.

Initial verification caught a test-matrix declaration incompatible with Swift Testing's two-collection limit and an incorrect copy-only test fixture's atomic output; both were corrected.

## Bluetooth avoidance and final acceptance

Bluetooth policy coverage includes built-in preference, Bluetooth LE, saved Bluetooth choices, disabled avoidance, no alternative, zero-channel, virtual and aggregate devices, missing saved choices, non-Bluetooth defaults, and all relevant lid states. The raw preference defaults on and round-trips as a boolean. Unit 6 reported 473 tests: 470 passed and 3 skipped, with 21 preference-dependent tests excluded. Physical microphone and closed-lid behavior remain manual checks.

The final unfiltered run reported **489 passed, 2 failed, and 3 skipped**, 494 tests in total. The failures were `OutputDuckerTests.savesOriginalAndLoweredValuesBeforeTouchingVolume` (`restoreRecordNotSaved`) and `OutputDuckingTests.slowVolumeChangesNeverDelayDeliveryButPrecedeTheSuccessSound` (no fake volume writes after the failed persistence). The three normal skips were the two opt-in release timing tests and the unavailable-model smoke test. These results are retained in `.cache/follow-ups/final-full-summary.json` and `final-verified-full-tests.log`.

The final available run enabled the existing latency probes with `SYRUP_RELEASE_TIMING=1` and `TEST_RUNNER_SYRUP_RELEASE_TIMING=1`, leaving their test bodies unchanged. It reported **472 passed, 0 failed, and 1 skipped**, with the 21 tests in the two preference-dependent suites explicitly excluded. The remaining skip was `availableModelSmokeTransformsShortPhrase`. Both release timing probes passed. Results are `.cache/follow-ups/final-acceptance-summary.json` and `final-acceptance-tests.log`.

The final universal unsigned Release build passed. The built app and embedded Sparkle framework both contain `x86_64` and `arm64`, and the built plist has the expected feed, public key, versions, profiling off, and automatic downloads off. A fresh unsigned test ZIP is 33,744,655 bytes. A fresh test feed was generated and its archive length and EdDSA signature verified against the public key. These are offline artifacts, not a distributable signed/notarized release. They live in `.cache/follow-ups/final-acceptance-feed/`.

Final source inspection preserved both manifest version lines, `IMPLEMENTATION.md`, `README.md`, `docs/RELEASE.md`, and every existing latency test body. `xcodegen`, Python parsing, shell syntax, and `git diff --check` passed. There is no configured repository lint command beyond the compiler. Three timing-assertion lines sensitive to unrelated main-actor work were removed; no application behavior changed.

## Manual follow-up

1. Rerun the unfiltered isolated suite in an environment where a fresh `UserDefaults` suite can synchronize successfully. Do not interpret the filtered run as a full-suite pass.
2. On an authorized app build, follow the new sections in `docs/QA.md` for updater presentation, correction-row edits, Paste Last permissions and focus changes, symbols, real-editor spacing, and physical Bluetooth/lid behavior. The automated verification did not exercise those desktop interactions.
3. Reconcile the owner's `docs/RELEASE.md` edits and add a pointer to `docs/UPDATES.md`.
4. For an authorized release, increase the manifest build number, then follow `docs/UPDATES.md` to prepare a signed, notarized candidate for review. Publication remains a separate explicitly authorized `--publish` action.
5. Verify one real update between two installed signed builds after publication is authorized. Neither the empty live feed nor the offline signature check establishes that acceptance result.

## Defect repairs after adversarial review

Implementation branch `feature/fix-follow-up-defects` starts at `3ce733f`. Adapted supplied repros failed there with 21 issues across six parameterized tests. Evidence is retained in `.cache/follow-up-fixes/baseline-red.log` and the preserved isolated xcresults under `.cache/follow-up-fixes/results/`. A standalone probe also reproduced ordinary-word corruption, all four original filler/symbol examples, and both correction boundaries in `.cache/follow-up-fixes/pure-baseline-red.log`.

### 1. Spoken symbols opt-in

Symbols now belong to the Transcribe kind, independently of cleanup, and default off. Missing options in v1, v2, and v3 blobs decode off. Existing `workflowListV3` storage and version stay unchanged. The old cleanup algorithm is preserved for symbols-off runs. A differential probe compares 1,680 generated English, Portuguese, and unsupported-locale cases against the source at `78b2b47`, including repeated fillers, adjacent formatting commands, quotes, accents, and symbols as ordinary words. All UTF-8 bytes match. Probe sources and output are `.cache/follow-up-fixes/cleanup-parity*` and `LegacyOracle.swift`.

An initial broader focused run passed all symbol/settings and cleanup checks but failed two existing recording-sidecar assertions in `WorkflowAbilitiesTests.transcriptionBypassesBrokenProviderAndDeliversAtomically`. Those failures are retained in `defect-1-green.log`; they are not counted as passes. The final unfiltered run passed these existing assertions without changes to their bodies. A narrowed run is recorded separately. No recording behavior or test body was changed for those failures.

Defect 1 focused green run passed all 6 tests in 4 suites, with no skips. The behavioral tests cover default-template ordinary text, additive old decoding, independent toggles, symbol expectations, and legacy filler/formatting expectations.

### 2. Fillers before symbols

Seven filler/symbol combinations failed in the baseline run. Cleanup now completes in its original formatting-then-filler order before symbol expansion. All seven required outputs pass, as do existing spoken-symbol and cleanup expectations. `defect-2-green.log` reports 4 tests in 3 suites passed, zero skips. The 1,680-case symbols-off byte comparison still passes in `defect-2-parity.log`.

### 3. Streaming spacing prefix

The real-typist integration repro failed at baseline for a single word, a short stream, and a stream exceeding the 200-character threshold. The prefix is now delivery metadata, added once when normalized content posts. `ModelOutputNormalizer` is unchanged. `defect-3-green.log` passed 18 tests in 3 suites, zero skips, including existing normalization, cadence, focus, secure-input, clipboard, and atomic-path checks. `defect-3-prefix-green.log` additionally passes the repeated-request and wrapper-normalization check. No real events or clipboard calls were used.

### 4. Last-result actions

Both Copy Last and Paste Last failed the baseline stale-revision repro. They now share a successful-result selector before falling back to the preserved revision base. `lastResult` itself and its capacity-eviction behavior are unchanged. The adapted regression explicitly checks that `lastResult` still exposes the older revision base while both user actions copy the newer success. `defect-4-green.log` reports 18 tests in 2 suites passed, zero skips. Existing recovery tests pass.

### 5. Combining marks and spacing

The baseline added spacing after U+FE0F, U+20E3, and U+0301. Isolated marks now use an unspaced fallback. The one-unit AX query remains unchanged, so a decomposed accented letter also gets no prefix; reading only its mark cannot establish that its base is a letter. A precomposed accented letter still qualifies. `defect-5-green.log` passed 6 tests in 2 suites, zero skips, including the actual trailing UTF-16 units of heart, keycap, and decomposed-accent fixtures.

### 6. Correction boundaries

Both phrase-before-hyphen and phrase-before-possessive cases failed at baseline. Corrections now treat hyphens as boundaries and allow trailing straight or curly apostrophes only before a possessive `s` ending at another boundary. Contractions and suffixes such as `'stuff` remain untouched. Cleanup's boundaries are unchanged. `defect-6-green.log` passed 9 tests in 3 suites, zero skips, including existing correction Unicode/overlap cases and legacy cleanup checks.

### 7. Nested signing

Git traces the `--deep` flag to `fcb3fc8`, the Sparkle integration commit. It was added beside the stable Debug signing-identity settings, but those settings predate Sparkle. The recorded history contains no explicit rationale or original failing command for recursive signing. Its role as a nested-signing workaround for the newly embedded framework is an inference, not a verified statement of the author's intent. Current Debug and Archive builds establish that it is unnecessary.

A baseline Developer ID universal Archive at `3ce733f` succeeded and passed nested signature verification, but all four helpers inherited Syrup's audio-input and network-client entitlements. That is the red signing repro. `signing-baseline-inspection.log` and `signing-regression-red.log` retain the exact inspection. The strengthened release verifier rejects this baseline in `release-verify-red.log`.

Removed `--deep` from both the manifest and the release command's explicit override. The corrected universal Archive and Developer ID export succeeded. `codesign --verify --deep --strict` passed for the archive, export, and ZIP extraction. `codesign -d --entitlements :-` showed only `org.sparkle-project.Sparkle.Autoupdate` on Autoupdate and empty entitlements on Updater, Downloader, and Installer. None carries Syrup's entitlements. All nested code has Developer ID team `TEAMID1234`, a timestamp, and hardened runtime. The app retains audio-input and network-client without get-task-allow. No helper or framework contents were stripped or removed.

The Developer ID Debug build also succeeded and passed nested signature and helper entitlement checks, so no Debug-only exception was needed. No signing artifact was launched. Evidence is `signing-fixed.log`, `signing-export.log`, `signing-regression-green.log`, `signing-export-inspection.log`, `debug-developer-id-build.log`, `debug-signing-inspection.log`, and `zip-signing-inspection.log`, under `.cache/follow-up-fixes/`. The release verifier passed its signing, entitlement, architecture, timestamp, and runtime stages, then stopped at the expected missing stapling ticket in `release-verify-green.log`. This is not a full release-verifier pass. Notarization was neither requested nor performed.

[Sparkle's distribution documentation](https://sparkle-project.org/documentation/#4-distributing-your-app) recommends Archive and Export so helper signing is correct. Its [signing guidance](https://sparkle-project.org/documentation/sandboxing/) explicitly excludes `--deep` from signing flags. The release verifier also now requests XML entitlement output with `:-`; the plain `-` form on this Mac emits a human-readable dictionary that `plistlib` cannot parse.

## ZIP size breakdown

The earlier 25,520,098-byte figure in `2026-11-01-speech-engines.md` describes an Archive, while the follow-up 33,744,655-byte test ZIP describes an ordinary Release build. The latter has an unstripped executable and its link command includes `-fprofile-instr-generate`. The Archive link command has no coverage instrumentation and Xcode runs `strip -D`. Comparing these artifacts as a Sparkle-only increase was incorrect.

Measured ZIP entries, in bytes, retain the original artifacts unchanged. Compressed entries exclude ZIP headers. `size-breakdown.py`, `size-breakdown.json`, and `size-breakdown.txt` under `.cache/follow-up-fixes/` retain the inspector and output.

| Artifact | ZIP | App executable raw | App executable compressed | Sparkle compressed | Other resources compressed |
| --- | ---: | ---: | ---: | ---: | ---: |
| Prior baseline ordinary build, no Sparkle | 32,714,996 | 78,716,368 | 28,868,530 | 0 | 3,809,636 |
| Follow-up ordinary build | 33,744,655 | 78,922,744 | 28,926,079 | 911,772 | 3,809,636 |
| Baseline Developer ID Archive with deep signing | 26,650,411 | 39,639,520 | 21,777,809 | 962,402 | 3,809,636 |
| Fixed Developer ID export without deep signing | 26,660,363 | 39,672,640 | 21,788,197 | 961,964 | 3,809,636 |

The comparable prior ordinary builds differ by 1,029,659 bytes, including 911,772 compressed bytes for Sparkle. The new complete ZIP is 7,084,292 bytes smaller than the follow-up test ZIP and 1,140,265 bytes above the historical 25.5 MB Archive. This local review artifact is `.cache/follow-up-fixes/Syrup-local-review.zip`. It is not notarized. No files inside Sparkle were removed or modified for size reduction.

Stripping a disposable copy of the old test executable changed it from 78,922,744 to 44,640,496 bytes. Its zlib-compressed size fell from 28,926,085 to 24,002,435 bytes. That isolates roughly 4.92 MB of compressed symbol overhead. The remaining difference from the Archive includes the instrumented build configuration. Coverage's individual contribution was not isolated by a second instrumented Archive. These are artifact byte counts, not launch or delivery performance claims.

The exported Sparkle framework contributes 2,767,129 raw bytes and 961,964 compressed bytes. Its five universal Mach-O files are 2,421,184 raw bytes and 827,765 compressed bytes. Their slices total 1,159,616 bytes arm64 and 1,137,392 bytes x86_64; fat headers, alignment, and padding account for the remainder. Localizations use 257,449 raw bytes and 97,458 compressed bytes. Remaining framework entries use 88,496 raw bytes and 36,741 compressed bytes.

| Sparkle binary | arm64 slice | x86_64 slice | Universal file | Compressed ZIP entry |
| --- | ---: | ---: | ---: | ---: |
| Sparkle | 468,560 | 479,424 | 976,464 | 362,366 |
| Autoupdate | 331,696 | 356,192 | 708,528 | 267,964 |
| Updater | 159,744 | 153,776 | 339,968 | 96,468 |
| Downloader | 90,624 | 66,880 | 188,928 | 45,242 |
| Installer | 108,992 | 81,120 | 207,296 | 55,725 |

The framework's deep-signed baseline is only 501 raw bytes and 438 compressed bytes larger than the exported framework without deep signing. Signature and entitlement differences explain this scale, not megabytes. The two app executables differ because the fixed artifact also contains the text repairs, so their small difference is not attributed to signing. Removing localizations or thinning signed Sparkle binaries would alter its signed contents and was not done.

## Final repair acceptance

The full unfiltered isolated run enabled the existing release timing probes through `SYRUP_RELEASE_TIMING=1` and `TEST_RUNNER_SYRUP_RELEASE_TIMING=1`. It passed **504 tests**, failed **0**, and skipped **1**, for **505 tests in 65 suites**. The skip is `availableModelSmokeTransformsShortPhrase`, whose required model is unavailable. Parameter-expanded device counts are 790 passed and 1 skipped. Both latency gates passed with unchanged test bodies. All existing preferences-dependent and recording-sidecar tests passed in this full run; no suites were excluded. Logs and xcresult summary are `final-full.log` and `final-full-summary.json`. The full xcresult is preserved as `final-full.xcresult`; all focused results are in `results/`. Disposable task build roots were removed after retaining these results and the baseline and fixed signed archives.

Python compilation, shell syntax, `xcodegen`, and `git diff --check` passed. The generated project was not edited.

The protected documents, both manifest version lines, and latency gate bodies remain unchanged. No push, notarization, private-key access, release creation, publication, real app launch, microphone, input events, clipboard, or production storage cleanup occurred. Real Settings interaction, physical devices, editor input, downloaded update presentation, and installed-build update transitions remain unverified under the task's explicit boundaries. The local ZIP is signing evidence, not a distributable release.
