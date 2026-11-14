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
2. Statecharts. One document, `docs/state-machines.md`, with a Mermaid statechart per machine, grouped by area, linked from ARCHITECTURE.md. Suspected defects from the inventory are checked before they are written down as findings.
3. Formal validation of the most important machines, by explicit-state model checking in Swift (the technique TLC uses):
   - A small checker in the test target explores every reachable state of a finite model breadth-first, checks invariants in each, checks that the idle state stays reachable from every reachable state (no stuck states), and returns the shortest counterexample trace.
   - Each model's actions include every event, async completion, timer, and cancellation, so all interleavings are explored. Where production already has a pure transition function (`PipelineTransitions.command`, `ReleaseTail.decision`, and others found in the inventory), the model calls it rather than restating it.
   - Conformance: traces from the model are replayed against the real types with deterministic fakes, and the observable state is compared after every step, so the model cannot drift from the code unnoticed.
   - Each model gets a mutation check: break one transition, show the checker or the conformance replay fails, restore.
   - TLA+ remains an option if Java is installed through the fleet; it is not needed for the above.

## Done when

- Every stateful type is in the inventory with an importance rating; trivial ones are listed as such.
- `docs/state-machines.md` has a statechart for every non-trivial machine, checked against the code.
- The High-importance machines have models, invariants, no-stuck-state checks, and conformance replays in the test target, each with a recorded mutation check.
- `script/ci_test.sh` passes.
- Findings (counterexamples, suspected defects confirmed or refuted) are listed in this plan with their status.

## Progress

- 2026-11-14: plan written; three inventory explorers started.
