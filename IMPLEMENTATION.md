# Development guide

Syrup is implemented and distributed as a macOS menu bar app. This guide covers the current development workflow. Historical verification reports are retained under `docs/verification/`.

## Build

`project.yml` is the project source. Never edit `Syrup.xcodeproj` directly. Regenerate with `xcodegen` after changing the manifest or adding/removing Swift files. Xcode resolves KeyboardShortcuts, WhisperKit, FluidAudio, and Sparkle through Swift Package Manager.

```sh
xcodegen
xcodebuild -scheme Syrup -configuration Debug build
```

Debug builds use ad-hoc signing by default and need no distribution certificate. Pass `SYRUP_CODE_SIGN_IDENTITY` and `SYRUP_DEVELOPMENT_TEAM` to `xcodebuild` with your own stable signing identity and team to preserve TCC grants across rebuilds. A compilation check does not establish permission behavior.

Open the built Debug `Syrup.app` for manual checks. The app appears in the menu bar and has no Dock icon. `script/launch_syrup_with_env.sh` can launch the newest Debug build with ignored `.env` endpoint settings; it terminates the running Syrup process first. Use it only when intentionally replacing that process.

## Test

```sh
script/ci_test.sh
# Existing production build; tests only:
script/test-isolated.sh
# Focused state-machine checks:
script/test-isolated.sh -only-testing:SyrupTests/AppStateTriggerTests
```

The isolated script copies components to a temporary checkout and uses a distinct bundle identifier and ad-hoc signing, so test preference domains never mix with an installed Syrup. Each run gets its own token in that bundle identifier (`org.syrup.SyrupIsolatedTests.<token>`), and tests name every preference domain through `testDomainName(_:)` as `<prefix>.<token>.<UUID>`, so cleanup removes only its own run's files and those of runs whose script has exited. Concurrent runs keep each other's preferences. Its temporary directory is deleted on exit by default. Set `SYRUP_TEST_ROOT` only when keeping build/results for diagnosis is useful; delete that task-owned directory afterward. Under XCTest the entry point (`SyrupMain` in `Sources/App/SyrupApp.swift`) starts an inert host, so even a direct `xcodebuild test` never registers hotkeys, starts model downloads, or runs retention cleanup.

`script/ci_test.sh` first runs `script/check-boundaries.sh`. It fails when an engine SDK (FluidAudio, WhisperKit, Sparkle, FoundationModels, KeyboardShortcuts), `Speech`, or `AVFoundation` is imported outside its folders, in any import form (`@_exported`, `@testable`, `import struct Module.Symbol`); when `Core/`, `Translation/`, or `Transcription/` imports SwiftUI or AppKit; when `Core/` names a type or free function declared in another folder; when a folder other than `Settings/`, `Onboarding/`, and `Hotkey/` names anything declared in `App/` (those three may use `AppState`, `UpdateController`, and `userMessage`); and when a `RunConfiguration` is built outside `RunConfigurationBuilder`. The type checks are grep-based over code with comments and string literals removed. `SYRUP_BOUNDARY_ROOT` points the script at another tree.

Async tests wait with `eventually` and `settleRun` from `Tests/SyrupTests/TestSupport.swift`, which also holds the shared pipeline fakes and `AppState.fixture(...)`, an `AppState` whose every service is a fake unless the test passes one. Wait for a signal, not a number of yields: `AppState.waitForPendingWork()` before asserting that nothing else happens, `SpyPipelineMetrics.bufferLevelCount` for a captured buffer reaching the run, or a fake's own counter.

There is no hosted CI. Run `script/ci_test.sh` locally for the production compilation and isolated suite. Tests use Swift Testing with protocol seams and controlled endpoint/process fixtures. Check the live microphone, speech permissions, editor focus, and pasted/typed output using [docs/QA.md](docs/QA.md).

## Source map

| Area | Responsibility |
| --- | --- |
| `Sources/App/` | Entry point, production wiring (`AppState.production`) and test host, menu, run state (`AppState`), the voice run's phases (`AppState+VoiceRun`), transformation and the delivery commit (`AppState+Delivery`), the event table (`PipelineTransitions`), editor delivery (`DeliveryCoordinator`), user messages, feedback, metrics |
| `Sources/Audio/`, `Sources/Transcription/` | Input devices, bounded live buffers, speech permission/assets, Apple transcription |
| `Sources/Translation/` | Prompt composition, the one `RunConfiguration` builder, provider configuration, atomic and streamed output |
| `Sources/Context/`, `Sources/Paste/`, `Sources/Clipboard/` | Opt-in selection, editor identity, paste/typing, clipboard commit/recovery |
| `Sources/Core/` | Domain types and text rules that use nothing from another folder: workflows and run configuration, providers, tones, speech engines, history snapshots, glossary, corrections, transcript cleanup, operation timeouts, the API-key store |
| `Sources/Settings/`, `Sources/Hotkey/` | Preferences (`AppSettings`), settings panes, shortcuts |
| `Sources/History/`, `Sources/Learning/` | Opt-in history, recording retention, Whisper cross-checks, proposals |
| `Sources/Stats/`, `Sources/Onboarding/` | Usage counts for Home (on by default, no content), first-run window |
| `Sources/RecordingCue/`, `Sources/Assets.xcassets/` | Recording/output feedback and app icons |
| `Tests/SyrupTests/` | Component and workflow regression tests |

`Transcriber` and `TextTransformer` are the engine/provider seams. `userMessage(for:)` (`Sources/App/UserMessage.swift`) maps typed boundary errors into the one line a person sees. UI state belongs on the main actor; heavy work and file operations use the established asynchronous paths. See [ARCHITECTURE.md](ARCHITECTURE.md) for contracts and [AGENTS.md](AGENTS.md) for privacy and clipboard invariants.

## Local files and evidence

- Copy `.env.example` to `.env` when using the optional launcher or evaluation scripts, then fill only the variables those scripts need. Keep `.env` local and ignored. Never print or commit its contents. Saved API keys live in the app-support secret store.
- `Syrup.xcodeproj` is generated and ignored. Its current package-resolution file is retained for local builds.
- Keep each release archive and its matching dSYMs under ignored `dist/` or `DerivedData/`. Verify that the symbols match the packaged binary before removing disposable exports and older build products. These generated files are not included in the source snapshot.
- The release script writes prepared ZIPs, checksums, and verification evidence under ignored `dist/`. A fresh checkout has no prepared release artifacts.
- Write results in dated `docs/verification/` or `docs/logs/` files. Record manual checks as passed, failed, unavailable, or unrun, and preserve measured durations and token counts without user content.
- Keep active task plans under `plans/syrup/YYYY-MM-DD/`. Remove completed plans when their useful results are covered by current docs or dated evidence.

The 1024-pixel app icon source is `Sources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`. Smaller variants remain referenced by the asset catalog.
