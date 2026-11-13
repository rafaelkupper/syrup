# Follow-up defect repairs

## Goal
Keep fast dictation and translation while preserving user text across the agreed follow-ups.

## Context
Baseline 3ce733f fast-forwarded from feature/syrup-follow-up-features. Reproduce each of seven defects before its repair. This branch is not pushed.

## Constraints
Use isolated tests and injected input posters only. No installed app, production bundle launch, microphone, clipboard, notarization, publication, private key access, or shared state changes. Preserve protected documents, version lines, and latency gate bodies.

## Done-when
- Symbols are a default-off Transcribe option with additive v3 decoding and legacy cleanup parity.
- Fillers precede symbols without changing legacy spoken formatting.
- Real streaming typist preserves an explicit spacing prefix separately from normalized provider output.
- Copy Last and Paste Last select the newest successful output before revision fallback.
- Combining marks use a conservative unspaced fallback.
- Correction boundaries accept hyphens and possessives but preserve contractions.
- Developer ID archive verifies with helper entitlements inspected, without notarization.
- ZIP growth is measured and documented.
- Focused red and green evidence and full isolated results are retained. One commit per defect.

## Progress
- Baseline merged. Source and supplied repros inspected.

## Throughput checkpoint
Use one retained isolated build root for focused checks, then one full suite. Run archive and size inspection after source checks. No latency claims are made from these checks.
- All six text defects reproduced at baseline. Symbol opt-in implemented, 1,680 legacy byte comparisons passed. Initial broader check found two existing asynchronous recording assertions; retain separately from focused acceptance.

- All seven defects repaired and verified. Full suite passed 504, failed 0, skipped 1. Universal Archive, export, ZIP extraction, and Developer ID Debug signatures verified. ZIP breakdown and manual boundaries recorded in docs/verification/2026-11-01-follow-ups.md. No push or notarization.
