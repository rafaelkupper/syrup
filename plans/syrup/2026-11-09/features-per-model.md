# Spoken edits per model

Personal identifiers and machine paths in this record use illustrative placeholders.

## Goal

the maintainer's decision on 2026-11-09: segment features by what each model can do.

- Compare Cerebras `qwen-3.8-27b` with `gpt-oss-120b` on the spoken-edit fixtures, and keep recommending the better one.
- OpenAI-compatible (and Codex CLI): the advanced spoken edits (self-corrections and formatting commands) are opt-in, with a warning that they need a capable model and a named recommendation.
- Apple On-Device: these features are off and can't be turned on; it keeps only what it does reliably.

## Context

- Evidence: `docs/verification/2026-11-09-model-comparison/` ran 22 synthetic fixtures three times through Syrup's real provider code for each model (198 requests).
  - Apple On-Device: plain translation 12/12, but self-corrections 12/21 (three fixtures failed every time), line breaks and paragraphs 0/12 (lists 6/6), and one invented sentence on a literal mention.
  - `qwen-3.8-27b` and `gpt-oss-120b` were both strong and close: 57/66 and 56/66 delivered.
  - Requested quotes reached the raw output in most runs for all three models, but Syrup delivered 0/18 because `ModelOutputNormalizer` strips any enclosing quote pair.
- `AppSettings.handlesSelfCorrections` and `handlesSpokenFormatting` are global toggles shown in the Translate workflow editor. A run's provider is `workflow.translationProvider ?? settings.translationProvider`.

## Constraints

- Smallest change: no new settings beyond what the UI needs; the two existing toggles are the advanced features.
- Follow AGENTS.md and preserve unrelated local changes.
- The output-contract prompt stays unchanged: the models already return requested quotes; changing the prompt needs a new evaluation.

## Status 2026-11-09

Built and verified.

- Comparison: 198 requests plus a 36-request rerun after the quote fix. `gpt-oss-120b` stays the recommendation; `qwen-3.8-27b` tied on totals but changed a weekday and doubled line breaks.
- Apple On-Device never receives the spoken-edit instructions; the editor disables both toggles with the cue. OpenAI-compatible and Codex CLI are opt-in (default off), with a warning and recommendation for OpenAI-compatible.
- Requested quotes are preserved across all providers and streaming, covered by nine new test methods. Three AppState tests cover the opt-in default.
- Isolated suite: 702 passed, 0 failed, 4 opt-in skips. Signed Debug build relaunched in place of the installed 0.10.2.
- Unverified: real speech, the UI in the running app, VoiceOver.

## Round two, 2026-11-10

the maintainer's first real test failed on a long Portuguese dictation. The self-correction and formatting instructions were rewritten and measured: 91/120 to 147/160 on 40 fixtures, with single features at 138/140 and multi-command dictations at 9/20. Higher reasoning effort and temperature 0 were tested and rejected. Isolated suite: 704 passed, 0 failed, 4 opt-in tests skipped. Open decision: whether to build deterministic layout (Syrup applies the commands and the model translates segments) for the multi-command case. See `docs/verification/2026-11-10-spoken-edits-round2/report.md`.

## Done when

- Apple On-Device runs never include the self-correction or formatting instructions, and the editor shows both toggles disabled with the reason.
- Other providers include them only when the user turns them on; the editor warns that they need a capable model and names the recommended one.
- "in quotes" / "entre aspas" output keeps its quotes in atomic and streaming delivery; unrequested wrapper quotes are still stripped.
- Focused tests, the isolated suite, and the Debug build pass; a live rerun of the quote fixtures shows delivered quotes.
- PRODUCT.md, ARCHITECTURE.md and docs/QA.md describe the behavior.
