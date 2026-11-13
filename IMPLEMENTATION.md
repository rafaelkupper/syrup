# Development guide

Syrup is implemented and distributed as a macOS menu bar app. This guide covers the current development workflow. Historical verification reports are retained under `docs/verification/`.

## Build

`project.yml` is the project source. Never edit `Syrup.xcodeproj` directly. Regenerate with `xcodegen` after changing the manifest or adding/removing Swift files. Xcode resolves KeyboardShortcuts and WhisperKit through Swift Package Manager.

```sh
xcodegen
xcodebuild -scheme Syrup -configuration Debug build
```

Debug builds use ad-hoc signing by default and need no distribution certificate. Supply your own stable signing identity and team to preserve TCC grants across rebuilds. A compilation check does not establish permission behavior.

Open the built Debug `Syrup.app` for manual checks. The app appears in the menu bar and has no Dock icon. `script/launch_syrup_with_env.sh` can launch the newest Debug build with ignored `.env` endpoint settings; it terminates the running Syrup process first. Use it only when intentionally replacing that process.

## Test

```sh
script/ci_test.sh
# Existing production build; tests only:
script/test-isolated.sh
# Focused state-machine checks:
script/test-isolated.sh -only-testing:SyrupTests/AppStateTests
```

The isolated script copies components to a temporary checkout, replaces the app entry point with an inert host, and uses a distinct bundle identifier and ad-hoc signing. Its temporary directory is deleted on exit by default. Set `SYRUP_TEST_ROOT` only when keeping build/results for diagnosis is useful; delete that task-owned directory afterward. Direct hosted `xcodebuild test` in the production project can initialize real hotkeys, recording retention, and model services.

There is no hosted CI. Run `script/ci_test.sh` locally for the production compilation and isolated suite. Tests use Swift Testing with protocol seams and controlled endpoint/process fixtures. Check the live microphone, speech permissions, editor focus, and pasted/typed output using [docs/QA.md](docs/QA.md).

## Source map

| Area | Responsibility |
| --- | --- |
| `Sources/App/` | Entry point, menu, run ownership/state, feedback, timeouts, metrics |
| `Sources/Audio/`, `Sources/Transcription/` | Input devices, bounded live buffers, speech permission/assets, Apple transcription |
| `Sources/Translation/` | Prompt composition, provider configuration, atomic and streamed output |
| `Sources/Context/`, `Sources/Paste/`, `Sources/Clipboard/` | Opt-in selection, editor identity, paste/typing, clipboard commit/recovery |
| `Sources/Settings/`, `Sources/Hotkey/` | Workflows, preferences, glossary, secret store, shortcuts |
| `Sources/History/`, `Sources/Learning/` | Opt-in history, recording retention, Whisper cross-checks, proposals |
| `Sources/RecordingCue/`, `Sources/Assets.xcassets/` | Recording/output feedback and app icons |
| `Tests/SyrupTests/` | Component and workflow regression tests |

`Transcriber` and `TextTransformer` are the engine/provider seams. `AppState` maps typed boundary errors into user-facing feedback. UI state belongs on the main actor; heavy work and file operations use the established asynchronous paths. See [ARCHITECTURE.md](ARCHITECTURE.md) for contracts and [AGENTS.md](AGENTS.md) for privacy and clipboard invariants.

## Local files and evidence

- Copy `.env.example` to `.env` when using the optional launcher or evaluation scripts, then fill only the variables those scripts need. Keep `.env` local and ignored. Never print or commit its contents. Saved API keys live in the app-support secret store.
- `Syrup.xcodeproj` is generated and ignored. Its current package-resolution file is retained for local builds.
- Keep each release archive and its matching dSYMs under ignored `dist/` or `DerivedData/`. Verify that the symbols match the packaged binary before removing disposable exports and older build products. These generated files are not included in the source snapshot.
- The release script writes prepared ZIPs, checksums, and verification evidence under ignored `dist/`. A fresh checkout has no prepared release artifacts.
- Write results in dated `docs/verification/` or `docs/logs/` files. Record manual checks as passed, failed, unavailable, or unrun, and preserve measured durations and token counts without user content.
- Keep active task plans under `plans/syrup/YYYY-MM-DD/`. Remove completed plans when their useful results are covered by current docs or dated evidence.

The 1024-pixel app icon source is `Sources/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png`. Smaller variants remain referenced by the asset catalog.
