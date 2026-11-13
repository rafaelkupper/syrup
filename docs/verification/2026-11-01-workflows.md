# Workflow routing and local transcription verification

Personal identifiers and machine paths in this record use illustrative placeholders.

## Result

Per-app routing and Transcribe are implemented on `feature/per-app-routing-transcribe-only`, based on accepted units at `46e368c`. The default primary shortcut still runs the active workflow with empty routing. Transcribe bypasses provider snapshotting, preparation, and calls, writes the clipboard once, and uses the existing atomic paste strategy. The implementation never launches the installed app or accesses the user's clipboard. Tests use spies and the inert isolated test host.

## Automated checks

Run from this worktree:

```sh
SYRUP_TEST_ROOT=/tmp/syrup-workflows-tests script/test-isolated.sh
```

The full suite passes with 443 Swift Testing tests in 50 suites. Parameterized cleanup and delivery cases count as one test declaration each. Tests also cover both clipboard paste and atomic type-text strategies. The latency gate test bodies in `AppStateTests.swift` are unchanged, including `latencyRegressionGateStartsTranscriptionAndProviderPreparationBeforeRelease` and `transformerProviderResolutionStartsBeforeRelease`.

Focused iteration used `-only-testing:SyrupTests/WorkflowAbilitiesTests`, `-only-testing:SyrupTests/TranscriptCleanupTests`, and `-only-testing:SyrupTests/AppSettingsTests`. Routing coverage includes old decode, stale-route normalization, route moves/deletion, primary fallback and routing, dedicated/revise precedence, next-run changes, caption reuse, locale warming only after a route is configured, and provider-request exclusion of the synthetic app identity. The frontmost seam observes no bundle-ID request with empty routing or an explicit shortcut.

Transcription coverage uses a provider that records a test failure if snapshotting or preparation is attempted, and a transformer that records a failure if called. The configured endpoint is broken, the key store is isolated and empty, and transcription still succeeds. Coverage includes one clipboard write, cancellation with no clipboard/history write, persisted history and the explicit snapshot, no Retry/fallback even for a failed transcription snapshot, revision through the configured provider, selection normalization, Codable round trips, cleanup-empty handling, and the glossary-learning archive.

The first full run failed one old test that assumed every template composed a model output contract. It now exhaustively asserts an empty prompt for Transcribe and the existing contract for transforming templates. Early iteration also caught compilation errors in test helper names and switches. These were corrected before the successful full suite. Xcode emitted an unrelated CoreSimulator version warning and linkd registration warnings; macOS hosted tests completed successfully.

## Routing cost

The measurement checks whether the added synchronous lookup is below 100 microseconds per trigger. It makes no claim about a user-visible latency difference. `script/measure-workflow-routing.sh` compiles the actual `Workflow.swift` and its domain dependencies with Swift 6.4.2, `-O -whole-module-optimization`, then runs the standalone CLI. It extracts the production TranslationProvider enum without compiling or launching the app. No defaults, network, secret store, or pasteboard are used.

The loop calls a non-inlined wrapper around `routedWorkflowID(for:)`, consumes the returned UUID, and asserts exact hit counts. Inputs alternate known and missing IDs. Empty and configured maps alternate order each round. Round 0 warms the code; ten measured rounds per mode each perform 1,000,000 lookups. Total work is 22,000,000 lookups including warmup, with exactly 5,500,000 configured hits and no errors.

| Map | Median ns/lookup | Range ns/lookup | Measured rounds |
| --- | ---: | ---: | ---: |
| Empty | 17.0474 | 16.8048 to 17.4214 | 10 |
| One configured route, half hits and half misses | 31.4824 | 30.9020 to 31.6125 | 10 |

The configured-map increment over the empty map is about 14.44 ns in this loop. The absolute numbers include wrapper, loop, UUID comparison, and Swift value/reference overhead. They are not an isolated hash-table primitive measurement. Production may inline the helper. Neither number includes NSWorkspace access or the rest of workflow resolution.

The resource counters show 0.55 s wall, 0.51 s user CPU, 0.01 s system CPU, no block I/O or swaps, and about 11.2 billion retired instructions. The limiter is the single-threaded CPU lookup/checksum loop. The host has 14 cores and had a load average near 6 while busy with unrelated work. Interleaving gives both modes the same load exposure. The observed spread is below the configured/empty gap. The measured upper lookup cost is about 0.000032 ms, below the microbenchmark acceptance threshold. Actual release-to-clipboard latency, speech assets, and provider performance are unmeasured here; the existing behavioral latency gates pass.

Raw timings are in `2026-11-01-workflow-routing-timings.tsv`. Resource counters are in `2026-11-01-workflow-routing-resources.txt`. Rerun the script to reproduce the measurement.

## Downgrade and blob decision

The older version-2 enum decoder rejects a blob containing `transcribeOnly`. Older `AppSettings.persistWorkflowList()` can then overwrite the undecodable blob after an edit. A version bump under the same key alone cannot prevent that old writer.

Version 3 therefore uses `workflowListV3`. It imports old version-1/version-2 workflows from `workflowListV1` and leaves the old bytes intact. A downgrade sees its pre-upgrade list, or a legacy default on a fresh V3 installation; it cannot erase V3 workflows. On upgrade, V3 takes precedence, so edits made in the downgraded build do not merge back. A regression test demonstrates rejection by the old enum shape, preservation of the old blob, and preservation of an undecodable future V3 blob after mutation. No durable instruction files were edited.

## UI locations and manual gaps

- Settings > Workflows > select a workflow > Use automatically in. Add application opens an application-only NSOpenPanel; choosing an already-routed app moves it to the selected workflow. Minus removes the route. Known saved IDs use LaunchServices lookups for bundle metadata, with no app-directory scan or discovery at Settings open. Missing apps show their bundle ID and remain removable.
- Settings > Workflows > New > Transcribe, or Transformation > Kind > Transcribe. The cleanup toggle is named Clean up fillers and spoken formatting. Source, selection context, target, tone, instruction, and provider override are hidden for this kind. The existing menu condition already restricts target/tone quick controls to Translate.

No manual control layout, application chooser interaction, real microphone/speech, physical shortcuts, actual clipboard, third-party paste, locale download, live provider revision, or old-build launch was exercised. `docs/QA.md` lists the exact checks. No push, deployment, or production launch was performed.

## Delivery receipts

Routing commit is `2267403`. Transcription commit is `cb4ce3e`. Final code verification used `/tmp/syrup-workflows-final.log` and produced `/tmp/syrup-workflows-tests/build/Logs/Test/<result>.xcresult`. The 443 tests passed after 1.656 seconds of Swift Testing execution. That duration is test execution time, not a dictation latency measurement. The local branch is `feature/per-app-routing-transcribe-only`; no push was performed.

The final transcription change adds 570 lines and removes 79. Redundant unsupported-locale test cases were removed; the existing UI layout conventions were retained.

## Settings rendering

The Settings panes render in a separate `org.syrup.SyrupUIVerify` host with a seeded workflow list. The host has no hotkeys, recording archive, or production defaults. Images are in `2026-11-01-settings/`. They show the Lower other audio toggle, the Transcribe kind with its cleanup toggle, hidden provider and source controls, and the Use automatically in section with an installed app and an uninstalled bundle ID.

The window capture uses `cacheDisplay`, which leaves white patches around some list rows. These are capture artifacts. No control was clicked, because the desktop-control permission request was canceled.
