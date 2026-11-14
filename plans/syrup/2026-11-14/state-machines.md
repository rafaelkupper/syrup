# State machines: inventory, statecharts, formal validation

## Goal

Find every implicit and explicit state machine in Syrup, document each as a statechart, and formally validate the most important ones against the code.

## Context

- Branch `state-machines`, stacked on `appstate-extraction` (`4837945`), which split `AppState` into owners. The statecharts describe that structure.
- About 30 stateful types across every source folder. Many machines are implicit: Bool flags, optional tasks, request IDs, continuations, timers, and files on disk.
- AGENTS.md hard rules decide importance: clipboard written only on success, cancel never clobbers it, privacy opt-outs delete or stay on, no stuck recording when a key is released while busy, Accessibility only for opt-in delivery.
- Tooling on this Mac (2026-11-14): no Java runtime, TLA+, Apalache, Quint, or Alloy. Node and Python exist.

## Constraints

- No behavior change unless validation finds a defect; a defect is reported first, with its counterexample, and fixed only as a separate, named change.
- Validation runs in the existing test target with Swift Testing, so `script/ci_test.sh` runs it. No new dependency or toolchain.
- Do not run the app or touch the real microphone, clipboard, or hotkeys. Commit on `state-machines` only. No push, merge, or release.
- Docs: lead with the result, straight quotes, no em dashes, dates as YYYY-MM-DD.

## Approach

1. Inventory. Three read-only explorers cover Hotkey/Paste/Audio/RecordingCue/Clipboard/Context, Transcription/Learning, and Translation/History/Stats/Settings/Onboarding/updates; the run pipeline in `Sources/App/` is analyzed directly. Each machine gets its state variables (file:line), states, events, transitions, invariants, existing tests, suspected defects, and importance.
2. Statecharts. An index, `docs/state-machines/README.md`, and one document per area with a Mermaid statechart per machine, linked from ARCHITECTURE.md. Suspected defects from the inventory are checked before they are written down as findings.
3. Formal validation of the most important machines, by explicit-state model checking in Swift (the technique TLC uses):
   - A small checker in the test target explores every reachable state of a finite model breadth-first, checks invariants in each, checks that the idle state stays reachable from every reachable state (no stuck states), and returns the shortest counterexample trace.
   - Each model's actions include every event, async completion, timer, and cancellation, so all interleavings are explored. Where production already has a pure transition function (`PipelineTransitions.command`, `ReleaseTail.decision`, and others found in the inventory), the model calls it rather than restating it.
   - Conformance: traces from the model are replayed against the real types with deterministic fakes, and the observable state is compared after every step, so the model cannot drift from the code unnoticed.
   - Each model gets a mutation check: break one transition, show the checker or the conformance replay fails, restore.
   - TLA+ remains an option if Java is installed through the fleet; it is not needed for the above.

## Done when

- Every stateful type is in the inventory with an importance rating; trivial ones are listed as such.
- `docs/state-machines/` has a statechart for every non-trivial machine, checked against the code.
- The High-importance machines have models, invariants, no-stuck-state checks, and conformance replays in the test target, each with a recorded mutation check.
- `script/ci_test.sh` passes.
- Findings (counterexamples, suspected defects confirmed or refuted) are listed in this plan with their status.

## Progress

- 2026-11-14: plan written; three inventory explorers started. All done-when items met on 2026-11-14; F1 to F3 await a decision on whether to fix them.
- Inventory: three explorers (Codex gpt-6.1-sol, max) reported 28 input/output, 37 speech/learning, and 54 providers/persistence/shell machines; the run pipeline has 13 charted and 6 small ones. Reports kept outside the repo; the area documents are curated from them and checked against the source.
- Validation tool chosen: explicit-state model checking in Swift (`Tests/SyrupTests/StateMachines/ModelChecker.swift`), with conformance replays against the real code. No Java on this Mac, so TLA+ would need a fleet change; not needed.
- `RunLifecycleModel`: 797 to 1,097 states per configuration (hold and toggle, automatic paste off and on). Every rule holds. Replay: every transition (135,000 steps) matched the real `AppState`; by default every state (6,931 steps, about 2 s).
- `FnShortcutModel`: 3,204 (hold) and 2,142 (toggle) states. Findings F1 (Fn option off leaves an Fn-started recording running; confirms the inventory's suspicion), F2 (the Fn latch outlives its run), F3 (stale Fn flags end a shortcut-started run). Replay of every transition (185,000 steps) matched the real controller, so all three are real. Recorded as known issues; F1 also reproduced directly by `FnShortcutFindingTests`. Not fixed: each is a behavior change for the user to decide.
- `LearningOptOutModel`: 340 states, 1,588 transitions. Every privacy rule holds. Replay of every state matched the real `PrivacyOptIns`, `RecordingFiler`, and `RecordingArchive`. The inventory's suspicion about a failed `deleteAll` is real behavior but breaks no rule (learning goes back on).
- Production changes, no behavior change: `PipelineState` is `Hashable`; `AppState.install(_:)` takes a `HotkeyController` built elsewhere.
- Statecharts: five documents in `docs/state-machines/` (index plus four areas), 138 machines, 117 charts, all parsed by Mermaid 11 through `html_preview` (a deliberately broken chart was shown to fail the same check). Three writers (Claude Opus) curated the area documents from the inventory and checked them against the source; they corrected several report claims and raised new unverified suspicions, listed in the index. Every link and line anchor resolves.
- Full replays run together once failed one step under main-actor contention with a 2 s barrier; the same deterministic tour passed alone, and with a 10 s barrier all three full replays pass together (134,652, 184,954, and 4,039 steps).
- `script/ci_test.sh` at `42b82ba`: boundary check passed, production build succeeded, 899 tests in 129 suites passed with 8 known issues (F1 to F3 in the Fn tests, plus the checker's two deliberate self-test failures), no compiler warnings. Later commits change only Markdown.

## Mutation checks

| Broken on purpose | Caught by | Restored |
| --- | --- | --- |
| `PipelineTransitions`: Esc cancels a committed run | `RunLifecycleModelTests` (automatic paste on, both modes) | Yes |
| `commit` no longer sets `deliveryCommitted` | `RunLifecycleConformanceTests` (the `committed` field) | Yes |
| `HotkeyController`: toggle mode arms after any tap | `FnShortcutConformanceTests` (toggle) | Yes |
| `RunLifecycleModel`: a new run no longer clears the flash | `RunLifecycleConformanceTests` (three configurations) | Yes |
| `PrivacyOptIns`: a failed opt-out no longer turns learning back on | `LearningOptOutConformanceTests` | Yes |
| `RecordingFiler`: commits after learning was turned off | `LearningOptOutConformanceTests` | Yes |

