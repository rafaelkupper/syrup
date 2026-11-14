# Review round 3

## Goal

Close the larger items the round-2 reviewers (GPT-6 Astra 7.5, Fable 5.2 7.5, Muse Wonder Full 8) left open, without changing product behavior beyond each item. Every reviewer claim is checked against the code first; a wrong claim is recorded here and skipped.

## Context

- Branch `review-round-3`, based on local `main` at `560c821` (round-1 and round-2 fixes merged, not pushed). Brief: `round-3-worktree-prompt.md`; earlier rounds: `review-fixes.md`.
- Baseline: 732 tests on `main` at `560c821`.

## Constraints

- AGENTS.md hard rules (privacy, secrets, clipboard, selection capture, permissions, settings), Swift 6 strict concurrency, Swift Testing.
- `xcodegen` after file adds/removes; never edit `Syrup.xcodeproj`.
- Do not edit AGENTS.md or CLAUDE.md. Update ARCHITECTURE.md, IMPLEMENTATION.md, docs/QA.md only where behavior or structure changed.
- Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md` or `syrup-releases`. Commits only on `review-round-3`; no push, merge, or release.
- Smallest change that satisfies each item.

## Claim checks

1. AppState hotspot: confirmed. `AppState.swift` is 1,934 lines; `runPipeline` spans lines 772-1052 (280 lines). `RunConfiguration(...)` is built by hand in `resolveRunContext`, `startRevision`, the post-transcript revision step in `runPipeline` (a fifth site), `retryTranslation`, and `AppSettings.runConfiguration`. `AppState.init` defaults to `ClipboardWriter()`, `AutoPaster()`, `AppFeedback()`, `SelectionReader()`, `StreamingTypist()`, `AudioRecorder`, `AppleTranscriber`, `KeychainStore()`, `UsageStatsStore()`, `NSWorkspace` and `DeliveryTarget.capture`, so a test that forgets a seam can touch the real clipboard, paste, notify, or write the real usage-stats file.
2. Layering: confirmed. `Core/Workflow.swift` uses `TranslationProvider` (defined in `Settings/AppSettings.swift`), `TonePreset` (`Translation/PromptBuilder.swift`), `DictationRecord.TransformationSnapshot` (`History/`), and `SpeechEngine` (`Transcription/`, which in turn reads `CanaryModel.languages`). Outside `App/`: `withOperationTimeout` is called from `Context/`, `Transcription/`, `Translation/`, `Learning/`; `runWhileMonitoring` and `awaitCancellableValue` from `Transcription/`; `PauseTransformation.isLoopback` from `Translation/` and `Settings/`; `SuccessSound` (App) from `Settings/AppSettings`. Settings views and Hotkey referencing `AppState`, `UpdateController`, and `userMessage` are UI composition and stay. The boundary script only matches `^import X$`.
3. Main-thread waits: confirmed. `DeliveryTarget.isCurrent()` is `@MainActor` and calls `AXUIElementCopyAttributeValue` synchronously (100 ms messaging timeout) from `StreamingTypist.flush`, `DeliveryCoordinator.targetIsCurrent`, `sentenceFit`, and Paste Last. The Codex runner writes stdin with a blocking `FileHandle.write` on a cooperative thread; a CLI that never reads a prompt over the 64 KB pipe buffer pins that thread until the timeout kills the process.
4. Codex framing: confirmed. `PromptBuilder.codexPrompt` appends the transcript or selected text after a bare `Input:` line. Measured with codex-cli 0.167.2 on 2026-11-13: with Syrup's current flags (`--sandbox read-only --ignore-user-config ...`), asking Codex to run `head -1 /etc/hosts` returned the file's first line, so the read-only sandbox still lets model shell commands read local files. The model ignored one injected instruction in a test, but the capability is there.
5. Smaller items: all confirmed. The `OPENAI_COMPATIBLE_*` fallback runs in every configuration. `resolvedGlossaryList` and `resolvedGlossaryProposals` return empty for an older or undecodable blob, and `persistVersioned` only protects a newer version, so the next edit overwrites it; a V3 workflow blob that fails to decode has the same gap. Force-unwraps: `Range(...)!` and `first { }!` in `TranscriptCleanup`, `mData!` in `PauseAudioCapture.copy`. Dead code: `SelectionReading.capture()` (production never calls it), `SelectionReader.captureSelectedText()` (system-wide path, unreachable), `OpenAICompatibleConfigurationProviding` with its static and environment providers, `CodexCLIConfigurationProviding` with its static provider.
6. Tests: confirmed. `pauseSettle` has 18 call sites; unconditional yield loops sit in `SpeechModelManagerTests.settle`, `PipelineSafeguardTests` (2), `ParakeetPipelineTests`, `AppStateTests` (2), and `ReleasePathTests.settle`. `AppStateTests.swift` is 3,016 lines. `test-isolated.sh` deletes every preference file matching the test prefixes under `~/Library/Preferences`, including files a concurrent run is using.

## Decisions

- Item 5, environment fallback: limited to Debug builds. Release builds ignore `OPENAI_COMPATIBLE_*`, so Settings always shows the source a Release run uses. `script/launch_syrup_with_env.sh` launches the Debug app, so the development workflow is unchanged.
- Item 5, unreadable blobs: an older-version or undecodable glossary, proposals, or V3 workflow blob is moved to a dated backup key (`<key>.unreadable.<unix-seconds>`) at load, then the key is cleared. A future-version blob stays in place as before.
- Item 4: Codex runs with the shell, web search, apps, plugins, browser, computer use, image tools, multi-agent, memories, and hooks turned off through `-c` overrides, plus `approval_policy="never"`. `-c` overrides were chosen over `--disable` because `--disable` exits with "Unknown feature flag" on a CLI that lacks a feature, while an unknown `-c` key only warns. The input is wrapped in a per-call random boundary and labeled as data.

## Done-when

- Every item is fixed or recorded here with a reason.
- `script/ci_test.sh` passes: boundary check, production Debug build, isolated suite.
- No new compiler warnings.
- New tests cover items 1, 4, 5, and the test-isolation fix.
- Report: test count, item 3 before/after timings, anything unverified.

## Progress

- 2026-11-13: claims checked (above), plan written, baseline CI run started.
