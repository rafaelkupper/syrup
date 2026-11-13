# Project cleanup verification

## Result

Removed obsolete local release/build products, completed implementation plans, unused scaffold code, and duplicate assets. The current 0.6 release remains available. Manifest/version, production behavior, credentials, unrelated local changes, and Git history are preserved. Commit and push of all pending changes were authorized on 2026-10-25.

## Removed

- Local 0.1 through 0.5 distribution ZIPs/checksums and old signing/notary/build output.
- All duplicate submission ZIPs, including 0.6, the exported 0.6 app copy, and bulky successful 0.6 build/CI logs. Compact current acceptance/verification evidence remains in `dist/`.
- Obsolete implementation guides, checklists, logs, and completed task plans. Current development, manual acceptance, and performance guidance is consolidated in IMPLEMENTATION.md and docs/QA.md. Obsolete plans were removed after their useful findings were consolidated.
- Six milestone-specific manual-result helpers and two obsolete standalone provider smoke helpers. The exact OpenAI smoke source list fails type-checking because TranslationProvider is missing; the Codex list fails because SuccessSound and subsequent settings dependencies are absent. These failures were verified without executing providers or reading credentials. Use current app connection/status checks and workflow QA instead.
- Uncalled DebugAudioRecorder, DebugTextTransformer, and DebugTranscriber implementations. Repository-wide symbol searches found no production call sites. Only DebugTranscriber's two scaffold tests depended on these types; those tests were retired with the type. Active production component and workflow tests remain.
- Root image.png, byte-identical by SHA-256 to the retained 1024-pixel icon asset, and Finder metadata. Every asset-catalog filename still resolves.

## Kept

- Source, 358 active tests, project.yml, entitlements, CI and isolated-test scripts, intentional environment launcher, and installed-Speech synthetic-audio check.
- Generated Xcode project and its local package-resolution file. Package pins still match the pre-cleanup file after regeneration.
- Current signed/notarized `dist/Syrup-0.6.zip`, portable checksum, and compact signature/entitlement/notary/ZIP evidence.
- The original cleanup reported retaining `DerivedData/Syrup-0.6.xcarchive`, its export configuration, and matching arm64/x86_64 dSYMs. The 2026-10-25 review did not find these artifacts; do not treat this earlier report as proof of current availability.
- Current product/architecture/QA/release documentation and dated release/review evidence. Release logs now distinguish historical outputs from currently retained artifacts.
- All 4,899 stored Git objects, refs, and reflogs. `git repack -d`, followed by `git repack --cruft -d --no-cruft-expiration`, compressed reachable and unreachable objects without expiration. Complete object-ID inventories, refs, and reflog hashes were identical before and after.

## Verification

- XcodeGen regeneration: passed.
- Production Debug build with signing disabled and task-local DerivedData: BUILD SUCCEEDED.
- Full isolated Swift Testing suite: 358 tests in 37 suites passed on rerun, reported duration 1.148 seconds. The original suite had 360 tests in 38 suites; the difference is the removed DebugTranscriber scaffold suite.
- First full run: one existing `cancelMidStreamLeavesTypedPrefixButNoClipboardOrHistory` test failed at its appended-prefix assertion. The test yields once after enqueuing a delta and can cancel before the consumer appends it. No changed production path called the deleted types. A fresh full run passed. This is a remaining test-ordering flake, not a measured product regression. No assertion was weakened or test disabled. A focused selection without Swift Testing's method suffix ran zero tests and is not counted as validation.
- Current ZIP checksum: unchanged, `2cd8fb064f0ff77653ca219b287a3f11e951483d369562f8ebd7df05c69b9c6a`. Re-extracted ZIP passed strict recursive signature, staple validation, and Gatekeeper with source Notarized Developer ID.
- Git fsck: exit 0. Pre-existing unreachable trees were retained, not pruned.
- Unrelated local changes, ignored environment configuration, package pins, and retained icon source: unchanged.
- Remaining shell scripts pass syntax checks; current Markdown link targets and app-icon entries resolve; git diff --check passes.
- Known host CoreSimulator mismatch and existing AX cast warnings were nonfatal. No live microphone, provider, permission, paste, or model operation was run for cleanup.

## Space and temporary files

Allocated project-folder usage was measured with `du -sk`, including ignored build/distribution files and .git. Before: 166,820 KiB. After: 70,408 KiB. Reclaimed: 96,412 KiB, or 94.15 MiB.

| Area | Before, KiB | After, KiB |
| --- | ---: | ---: |
| Git object storage | 45,980 | 12,140 |
| Distribution files | 56,432 | 5,576 |
| Archive/export directory | 58,408 | 48,876 |

Verification used task-owned temporary directories. The isolated test script cleaned up its copies automatically; the temporary production build and working logs were removed after their outcomes were recorded here. No shared Xcode caches, installed app, user history, or recordings were deleted.


## Retention follow-up: 2026-10-25

The release ZIP still passes its SHA-256 check. However, `DerivedData/` is absent, and the 0.6 archive was not found in the project, the standard Xcode Archives location, or Spotlight results. The ZIP contains no dSYMs. The cause and timing of the loss are not established. Locate or restore the exact release archive and compare its dSYM UUIDs with the shipped executable. A new build does not establish matching symbols for the existing release.

The user authorized committing and pushing the pending cleanup and correctness fixes to main on 2026-10-25. This authorization does not resolve the missing archive.
