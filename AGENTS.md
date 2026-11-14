# AGENTS.md — working on Syrup

Syrup is a macOS menu bar app: global hotkey → dictation → on-device transcription → one-shot text transformation workflow → clipboard or optional auto-paste. The default workflow is translation, but workflows can also polish, summarize, draft replies, or run a custom instruction. The name `Syrup` is used everywhere: product, app, Xcode target, scheme, and Swift module.

Consult `PRODUCT.md`, `ARCHITECTURE.md`, and `IMPLEMENTATION.md` when they are
relevant to the task. Update only the documents affected by a meaningful change
to behavior, structure, or an API.

## Project setup & build

The Xcode project is generated — **never edit `Syrup.xcodeproj` directly**. Edit `project.yml` and regenerate:

```sh
brew install xcodegen            # once
xcodegen                         # regenerate Syrup.xcodeproj after project.yml or file add/remove
xcodebuild -scheme Syrup -configuration Debug build   # build
script/ci_test.sh                                      # boundary check, production build, isolated tests
script/test-isolated.sh                                # tests only
```

Under XCTest the app's entry point (`SyrupMain`) starts an inert host, so `xcodebuild -scheme Syrup test` never registers hotkeys, starts model downloads, or runs retention cleanup. `script/test-isolated.sh` additionally runs from a temporary copy under its own bundle ID, which keeps test preference domains away from an installed Syrup; prefer it.

Adding/removing Swift files requires re-running `xcodegen` (targets use directory globs, so usually just regenerate — no `project.yml` edit needed).

To run the app for manual testing: `open` the built `.app` from DerivedData, or run from Xcode. It appears in the menu bar only — no dock icon, no window.

## Conventions

- Swift 6 strict concurrency; `@MainActor` for UI/state, async/await elsewhere. No DispatchQueue unless bridging an old API.
- SwiftUI only; no storyboards/xibs. AppKit (`NSPasteboard`, `NSStatusItem` internals) is wrapped in small dedicated types.
- Tests use **Swift Testing** (`@Test`, `#expect`), not XCTest.
- The two seams are protocols: `Transcriber` (one `transcribe(_:request:)` taking a `TranscriptionRequest`) and `TextTransformer`. Providers are reached through `TransformerSnapshotting`, which freezes a run's configuration into a `TransformerSnapshot`. New engines/providers implement these; don't leak engine-specific types outside their module. `script/check-boundaries.sh` enforces which folders may import each engine SDK and keeps UI frameworks out of `Core/`, `Translation/`, and `Transcription/`.
- Errors: typed errors per module, mapped to one user-facing message at the `AppState` boundary. Never show raw error dumps in notifications.

## Hard rules

- **Secrets:** the API key lives in the local app-support secret store via `KeychainStore` (legacy type name), not in macOS Keychain — originally because ad-hoc Debug signing triggered repeated Keychain password prompts. Local builds use ad-hoc signing by default; a developer-supplied stable signing identity can preserve TCC grants across rebuilds. The file-based store stays. Never write the key to UserDefaults, logs, or test fixtures.
- **Privacy:** audio is never logged and never written to disk. Transcripts, transformation results, workflow names, workflow instructions, glossary terms/mishearings, and captured selections are user content: never log them. Persist transcripts/results only when the user explicitly enables Persist history; captured selections are never persisted, even then. A cloud-backed provider receives only the finalized transcript or selected-text input plus the composed run instruction, which may include the user's glossary block and opt-in selection context needed for that run; a revision sends the captured previous result plus the current composed revision instruction. Never send unrelated history or content. Usage stats (on by default, off in Settings) are the one behavior store outside those opt-ins: per-day word, duration, and fix counts and the frontmost app's bundle ID, with no transcript, result, or other content.
- **Selection capture:** reading another app's selection is opt-in per workflow and uses Accessibility only. Captured text is trimmed, capped at 20,000 characters, retained only for the active run, and excluded from history snapshots. Never add a synthesized Command-C fallback without an explicit product decision because it would touch the user's clipboard.
- **Clipboard:** only written on successful completion (or explicit transcript-fallback). Cancel must never clobber the user's clipboard.
- **Permissions:** Accessibility is intentionally used only for opt-in auto-paste (including smart spacing and pinned delivery), opt-in sentence fit at the cursor (which reads a bounded window around the caret even with auto-paste off), and per-workflow selection capture. Anything else requiring a new TCC permission (Input Monitoring, Screen Recording, etc.) is a product decision — flag it, don't just add it.
- **Settings:** scalar preferences stay as raw strings/bools/integers in UserDefaults. The structured versioned JSON blob exceptions are the workflow list (`workflowListV3`; `workflowListV1` is read only as a legacy import), personal glossary (`glossaryV1`), and glossary proposals (`glossaryProposalsV1`). A blob written by a newer build loads empty (the workflow list falls back to the default workflow) and is never overwritten. A blob this build cannot read is copied once to `<key>.unreadable.<digest>` before an edit replaces it; it holds user content, so only the newest backup per key is kept. The one other structured value is runtime state, not a preference: `outputVolumeRestore`, a property-list dictionary of the output device's UID and its original and lowered channel volumes, written while recording lowers other audio and removed once the volume is restored. Secrets never go in UserDefaults.

## Testing expectations

- State machine, `PromptBuilder`, settings, glossary model/storage, history,
  auto-paste, and transformer logic have useful unit-test seams. Add focused
  tests when changing meaningful logic in those areas.
- Real audio, speech, and hotkey behavior may need the manual smoke checklist in
  `docs/QA.md`. Run the relevant checks when practical; otherwise report what
  remains unverified without blocking unrelated progress.

## Gotchas

- Speech framework auth + mic auth are two separate permissions; both must be handled (the new SpeechAnalyzer API still requires `NSSpeechRecognitionUsageDescription`).
- Transcription uses `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+), one locale at a time from the triggering workflow's `dictationLocaleID`. `supportedLocales` ≠ `installedLocales` — assets for a locale must be installed via `AssetInventory.assetInstallationRequest(supporting:)` before transcribing, and the UI must handle the not-yet-downloaded state.
- Hold-to-talk uses keyDown/keyUp pairs; watch for stuck states when the key is released while the app is busy (the state machine must handle keyUp in every state).
- Ollama/LM Studio base URLs include `/v1`; don't double-append path segments when building the request URL.
- `TranslationError` keeps its historical name even though providers now implement `TextTransformer`; renaming the persisted setting/error domain is churn with no product value.
