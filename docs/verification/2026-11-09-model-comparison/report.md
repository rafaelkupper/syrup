# Spoken edits by model: gpt-oss-120b, qwen-3.8-27b, Apple On-Device

Verified on 2026-11-09. 198 requests, all completed: 22 synthetic fixtures, three runs each, per model.

## Result

| Feature (runs per model) | gpt-oss-120b | qwen-3.8-27b | Apple On-Device |
|---|---:|---:|---:|
| Plain translation and cleanup (12) | 12 | 12 | 12 |
| Self-corrections (21) | 19 | 19 | 12 |
| Line breaks, paragraphs, lists (18) | 17 | 17 | 6 (lists 6/6, breaks 0/12) |
| Requested quotes, raw model output (6) | 3 | 6 | 6 |
| Requested quotes, delivered by Syrup (6) | 0 | 0 | 0 |
| Literal mentions kept as text (9) | 8 | 9 | 8 |
| **Delivered total (66)** | **56** | **57** | **38** |
| Request time, median / p90 / max | 370 / 453 / 998 ms | 325 / 502 / 2334 ms | 366 / 485 / 1592 ms |

- The two Cerebras models are effectively tied on this set. One run apart is noise at this sample size.
- Qwen's distinctive failure is the most harmful kind: in 2 of 3 runs it translated "quarta-feira às quatro" as "Thursday at four", a silent change of meaning. gpt-oss-120b's misses were visible: it kept the replaced option once in two cases, left "bom dia" untranslated inside requested quotes (3 of 3), and once turned a literal "new line" into a line break. Recommendation: keep `gpt-oss-120b`.
- Apple On-Device handles plain translation, and lists, but not self-corrections (three of seven cases failed every time: it translated "no", "actually" and "digo" literally) or line breaks and paragraphs (it dropped them, kept the command words, or inserted "-"). With the formatting instruction present it once replaced "Please add a new paragraph to the contract." with an invented sentence. These features are off for Apple On-Device.
- Every model returned the requested quotes in most runs, and Syrup delivered none: `ModelOutputNormalizer` strips any enclosing quote pair. That is an application bug, fixed separately.
- Qwen begins every reply with two newlines left over from its reasoning. Syrup trims them on both the atomic and streaming paths (`StreamingTypist` drops leading whitespace), so they never reach the editor.

## After the quote fix

`after-quote-fix/` reran six fixtures twice per model against the fixed code (36 requests, all completed). Requested quotes were delivered in 10 of 12 runs; the two misses are gpt-oss-120b keeping "bom dia" untranslated inside them, which no Syrup change can fix. The same rerun repeated two earlier patterns: Qwen turned a single "new line" into a blank line in both runs (3 of 5 overall), and Apple On-Device, with the formatting instruction present, answered "Please add a new paragraph to the contract." with invented contract text in both runs (3 of 5 overall). Apple runs no longer receive that instruction.

## Method

- `CerebrasHarness.swift` compiles and calls Syrup's real `OpenAICompatibleTransformer`, `PromptBuilder`, SSE parser, normalizer, and timeout code with the production request (temperature 0.3, system and user messages, no reasoning or token overrides). A recording transport keeps the final response content, model ID, finish reason and token usage; never the key, headers or reasoning text.
- `AppleHarness.swift` calls Syrup's real `AppleOnDeviceTransformer` with a fresh session per run, as production does. `AppleSupport.swift` swaps only the normalizer hook, so the raw text is recorded and the real `ModelOutputNormalizer` is applied afterwards for the delivered text.
- Prompt: the production Translate prompt to English, neutral tone, no glossary, with both spoken-edit instructions on. Inputs are English and Portuguese synthetic dictations; no microphone, user transcript, history, glossary or settings were read or sent.
- `evaluate.py` checks required and forbidden words, exact line and paragraph structure, list markers and enclosing quotes. After reading the outputs, two checks were widened to accept correct translations ("deployment" for "deploy", "release" for "lançamento"); before that, all three models were marked down for them.
- Request time is wall-clock from this Mac through Syrup's transformer, network included, for non-streamed requests. It is not time to first token.
- The source files compiled by the harnesses match commit `c162d8e`.
- Bounded regression fixtures, not a general accuracy benchmark. Real speech, other languages, and arbitrary dictations are untested.

## Reproduce

The Cerebras key is read from `CEREBRAS_API_KEY` in the repository's git-ignored `.env`. From the repository root:

```sh
docs/verification/2026-11-09-model-comparison/run.sh cerebras gpt-oss-120b 3
docs/verification/2026-11-09-model-comparison/run.sh cerebras qwen-3.8-27b 3
docs/verification/2026-11-09-model-comparison/run.sh apple 3
python3 docs/verification/2026-11-09-model-comparison/evaluate.py
```

Results append to `results.jsonl`, and completed case keys are skipped, so use a fresh directory for an independent repeat.
