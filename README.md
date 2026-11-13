# Syrup

Speak once and get translated, polished, summarized, or custom-shaped text on your clipboard.

Syrup is a macOS 26+ menu bar app. Hold a hotkey or press to toggle, dictate, and let on-device Speech transcription feed a one-shot workflow. Workflows can also use selected text, and completed results can be revised, re-copied, or optionally pasted into the source editor.

Transformation providers are OpenAI-compatible endpoints, Apple On-Device, and the local Codex CLI. Optional glossary learning uses recordings and WhisperKit on the Mac to propose spelling corrections.

The source version is 1.0/build 13. Versions live in `project.yml`; release artifacts stay under ignored `dist/`. Publisher-specific signing and update settings are supplied when preparing a release.

## Develop

Install Xcode 26+ and XcodeGen, then generate and build:

```sh
brew install xcodegen
xcodegen
xcodebuild -scheme Syrup -configuration Debug build
```

Local builds use ad-hoc signing and need no distribution certificate. To preserve macOS permission grants across rebuilds, pass your own stable signing identity and team to `xcodebuild`.

The source uses the neutral bundle identifier `org.syrup.SyrupApp`. It has a separate preferences domain and secret-store namespace from older private builds. Existing local data is not migrated. In-app updates stay inactive until a publisher supplies both `SYRUP_UPDATE_FEED_URL` and `SYRUP_UPDATE_PUBLIC_KEY`; see [docs/UPDATES.md](docs/UPDATES.md).

Run automated checks with `script/ci_test.sh`. It compiles the production app and runs tests in an isolated, inert app host. It does not start production hotkeys, clean up user recordings, or download models.

## Project guide

- [PRODUCT.md](PRODUCT.md): user tasks, behavior, and scope.
- [ARCHITECTURE.md](ARCHITECTURE.md): pipeline, modules, and decisions.
- [AGENTS.md](AGENTS.md): development rules.
- [IMPLEMENTATION.md](IMPLEMENTATION.md): build, test, and source navigation.
- [docs/QA.md](docs/QA.md): live-app checks and performance measurements.
- [docs/RELEASE.md](docs/RELEASE.md): signing, notarization, and artifact retention.

Swift 6 and SwiftUI provide the app and settings. SpeechAnalyzer/SpeechTranscriber handle dictation, FoundationModels handles Apple On-Device transformation, URLSession handles compatible endpoints, KeyboardShortcuts handles global hotkeys, and XcodeGen generates the project.
