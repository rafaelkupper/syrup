Work in this Syrup worktree on branch `review-round-3`, based on `review-fixes`. Read AGENTS.md, ARCHITECTURE.md, and `plans/syrup/2026-11-13/review-fixes.md` first. Two earlier rounds of architecture review were fixed there. This round covers the larger items the round-2 reviewers (GPT-6 Astra 7.5, Fable 5.2 7.5, Muse Wonder Full 8) left open. Write your plan to `plans/syrup/2026-11-13/review-round-3.md` (Goal / Context / Constraints / Done-when) and keep its Progress section current.

Goal: make each item below true without changing product behavior beyond the item itself. Verify every reviewer claim against the code before fixing it. If a claim is wrong, record that in the plan and skip it.

1. AppState is still the hotspot (about 1,920 lines; `runPipeline` about 280).
   - Split `runPipeline` into named phases: recording/transcription, then transformation/delivery. These can be types or files. They should not be one long function.
   - Make one `RunConfiguration` builder. It is currently rebuilt by hand in four places: `resolveRunContext`, revision start, retry, and `settings.runConfiguration`.
   - `AppState.init` defaults to production services. Move production wiring into the app entry point so tests must inject every seam.
   - Keep `PipelineTransitions` as the only event table, and keep `commit(_:runID:recordReleaseToClipboard:)` as the only delivery commit point.
2. Folder layering.
   - `Core/` must not use types from `Settings/`, `Translation/`, or `History/`. For example, check where `TranslationProvider` and the history transformation types are defined. Move shared domain types down into `Core/`.
   - `Translation/` and other folders must not call helpers that live in `App/`, such as `PauseTransformation.isLoopback` (use `EndpointPolicy`) and `OperationTimeout`.
   - Extend `script/check-boundaries.sh` to catch `import struct/class/enum/func` and `@_exported import`. Cover `Speech` and `AVFoundation`. Add a type-reference check for the `Core/` rule, even if it stays grep-based.
3. Main-thread waits.
   - `DeliveryTarget.isCurrent()` makes a synchronous Accessibility call on the main actor, once per typing flush, with up to a 100 ms timeout. Move it off the main actor without breaking the per-flush ordering guarantee in `StreamingTypist`.
   - The Codex CLI stdin write can block a thread if Codex stops reading. Make it non-blocking or bounded by the existing timeout.
   - Measure before and after, and record the numbers in the plan.
4. Codex prompt framing (Fable's inference; verify it first). Selected text and transcripts reach the Codex CLI without being marked as untrusted data, so hostile selected text could try to make Codex read local files. Check the current Codex CLI flags in the official docs: sandbox mode, approval policy, and tool restrictions. Run it with the most restrictive mode that still works, and delimit the user content as data. Add a test that pins the invocation arguments.
5. Smaller items.
   - The `OPENAI_COMPATIBLE_*` environment fallback is active in Release builds while Settings shows the saved URL. Limit it to Debug, or show the active source in Settings. Pick one, and say which in the plan.
   - A glossary or proposals blob with an older version, or one that won't decode, loads empty, and the first edit then overwrites it. This happens in `resolvedGlossaryList` and `resolvedGlossaryProposals` in AppSettings. Preserve the original, either by migrating it or by moving it to a backup key. Do the same for workflows if that path has the same issue.
   - Remove the force-unwraps in `TranscriptCleanup` and `PauseTransformation`.
   - Delete the dead code: `SelectionReading.capture()` and any configuration-provider protocols that are no longer used.
6. Tests.
   - Replace the remaining fixed-yield waits with condition or completion signals. This includes `pauseSettle` (about 18 call sites) and the five unconditional "nothing else happens" yield loops listed in the review-fixes plan.
   - Split the roughly 3,000-line `AppStateTests.swift` by subject. Split `StaleAndFailedStateTests` and `PipelineSafeguardTests` the same way.
   - Concurrent `script/test-isolated.sh` runs can delete each other's preference files. Give each run its own bundle ID suffix or its own preferences directory.

Constraints:
- Follow AGENTS.md hard rules (privacy, secrets, clipboard, selection capture, permissions, settings), Swift 6 strict concurrency, and Swift Testing. Run `xcodegen` after adding or removing files. Never edit `Syrup.xcodeproj`.
- Do not edit AGENTS.md or CLAUDE.md. Update ARCHITECTURE.md, IMPLEMENTATION.md, and docs/QA.md only where behavior or structure changed.
- Do not touch `docs/logs/2026-11-13-syrup-1.0-public.md` or the `syrup-releases` repo. Do not commit to `main`, push, or release without an explicit go.
- Prefer the smallest change that satisfies each item.

Done when:
- Every item is fixed or recorded in the plan with a reason.
- `script/ci_test.sh` passes: boundary check, production Debug build, and the isolated suite. The baseline is 732 tests on `review-fixes`.
- There are no new compiler warnings.
- New tests cover the items that change behavior (1, 4, 5, and the test-isolation fix).
- Report the test count, the before and after timings from item 3, and anything left unverified.
