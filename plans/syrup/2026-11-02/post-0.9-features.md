# Syrup features after 0.9

Personal identifiers and machine paths in this record use illustrative placeholders.

## Goal

Build what the maintainer queued that 0.9 did not ship: self-corrections, spoken formatting, Home usage stats, and new speech models with a model list.

## Context

0.9 shipped Fn alone. The maintainer said to build the rest on 2026-11-02. Decisions left open use the recommendations already given to the maintainer: prompt instructions apply to the default Translate prompt only, per-app word counts stay on this Mac, and the model list has accuracy and speed bars from real measurements.

## Constraints

- Translation speed stays the main feature. Nothing here may slow a run with these features off, and stats must not delay delivery.
- No transcript or result text is stored for stats. Counts only, on this Mac. Audio and user content are never logged.
- Custom prompts stay exactly as written.
- No new TCC permission. New binary dependencies are a product decision.
- Existing downloads, settings, and workflows keep working.
- No commit, push, notarization, or publish without the maintainer's word.

## Models

- Nemotron Streaming 3.5: `FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML`, `multilingual/2240ms`, 640 MB on disk, FluidAudio already supports it.
- Parakeet Unified EN 0.6B: `FluidInference/parakeet-unified-en-0.6b-coreml`, streaming int8 files only.
- Canary 180M Flash: only NeMo, ONNX, and GGUF exist, so it needs an ONNX runtime. Stop and report; do not add the dependency unasked.

## Done when

- Each setting changes the Translate prompt only when on, and custom prompts are unchanged.
- Stats survive restarts, hold no text, and can be turned off and deleted.
- Each supported model downloads, deletes, and transcribes real audio, with measured accuracy and speed.
- The isolated suite and production build pass, and new pages are inspected.
- Docs are updated and what remains unverified is reported.

## 2026-11-04: Parakeet Ultra and Redux

the maintainer chose Parakeet Ultra to replace v3 and Redux as a small download, after the Portuguese comparison in `docs/verification/2026-11-03-portuguese-models.md`.

- Workflows that chose v3 keep a Parakeet: the stored `parakeet_v3` reads as Ultra.
- A v3 download left from 0.9 is removed at launch and Ultra downloads in its place, so a user who chose a local model keeps one.
- Redux runs its encoder on the GPU. On the Neural Engine its first load compiles for several minutes.
- Bars come from the same synthetic clips as the other models, so the list stays comparable.

Done when both download, load, and transcribe real audio through Syrup's code, the old v3 folder is replaced in a test, the suites and production build pass, and docs show the new models.

Status 2026-11-04: built and verified. Redux runs on the Neural Engine after all: on real clips it finished in 80 ms at the median against 143 ms on the GPU, at the cost of a 6-minute first load. The bars moved from synthetic voices to FLEURS recordings because Redux broke down on the synthetic voices. Results are in `docs/verification/2026-11-04-parakeet-ultra-redux.md`.
