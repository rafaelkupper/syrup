# Cerebras gpt-oss-120b spoken-edit evaluation

Verified on 2026-11-09 against https://api.cerebras.ai/v1/chat/completions.

## Result

Cerebras handled the tested self-corrections, line breaks, paragraphs, and lists with Syrup's current prompt. The current application still damages requested quotes. A literal mention of "new line" was misinterpreted once. This narrows the recommended first repair to quote handling and targeted behavior tests; it does not justify adopting the earlier full formatting parser immediately.

All 88 evaluation requests completed with response model `gpt-oss-120b` and `finish_reason: stop`. A separate small connectivity request returned OK. No request errors, timeouts, or truncated completions occurred.

## Method

- `Harness.swift` compiles and calls the repository's actual `OpenAICompatibleTransformer`, `PromptBuilder`, SSE parser, normalizer, and timeout code. `Support.swift` contains only extracted workflow and transformer protocol declarations to avoid launching Syrup.
- Requests use the production temperature 0.3 and system/user messages. No reasoning effort or token limit override was added; model-specific defaults apply. A recording transport captures only final response content, model ID, finish reason, and token usage. Reasoning text and authorization headers are not written to the artifacts.
- Baseline and focused-prompt arms each use the same 16 synthetic English/Portuguese fixtures, repeated twice. Assertions check required/forbidden semantic tokens, exact line/paragraph counts, list structure, and quotes. Outputs were also read directly for the reported failures. These are bounded regression examples, not a general accuracy benchmark.
- Quote-contract-only uses four selected fixtures twice. The layout prototype uses six presegmented fixtures twice. Neither smaller set is directly comparable to the full baseline's pass fraction.
- The four streaming cases use the production SSE parser. The recording transport buffers each full HTTP response before replaying it to that parser, so this checks response handling and final text, not real-time cadence or latency.
- Inputs contain only synthetic dictation. No microphone, clipboard, user transcripts, stored history, or user glossary was read or sent. No user settings or production code changed.

## Fixture checks

| Arm | Requests | Raw model outputs meeting checks | Delivered outputs meeting checks |
|---|---:|---:|---:|
| Current prompt | 32 | 29/32 | 27/32 |
| Quote-contract-only change | 8 | 7/8 | 4/8 |
| Focused prompt change | 32 | 31/32 | 27/32 |
| Presegmented layout prototype | 12 | Not comparable: structured segments | 12/12 |
| Current prompt, streaming | 4 | 4/4 | 3/4 |

"Delivered" includes Syrup's current normalizer, except the layout prototype, which uses its proposed local renderer. Raw and delivered results are from the same response; there is no resampling between those checks.

## Findings

1. All ten baseline self-correction outputs selected the final name, date, time, or quantity. Basic newline, paragraph, bullet-list, and numbered-list cases also passed. This does not disprove the user's earlier Apple-model failure or establish all speech cases work.
2. All four baseline quotation outputs lost their enclosing quotes in Syrup. For `In quotes hello.`, Cerebras returned `"hello"` twice; Syrup delivered `hello` twice. The two Portuguese quotation outputs additionally retained `bom dia` instead of the fixture's expected English `good morning`.
3. One of two baseline outputs for `The phrase new line appears in the manual.` inserted a newline and deleted the literal words. This is a model interpretation error that quote normalization cannot fix.
4. Rewording only the output contract did not fix normalization. One Portuguese quote still remained untranslated. These samples do not establish a reliable prompt-only repair.
5. The focused prompt added explicit rules for translating quoted text and preserving literal mentions. Its raw output met 31 of 32 checks, but one Portuguese date-correction output retained the rejected Tuesday/three choice. Because this introduced a consequential error, it is not ready to adopt as the new default. Its delivered quote outputs still fail with the unchanged normalizer.
6. The presegmented layout prototype met all 12 checks. It supplies segment boundaries and quote scope as fixtures, translates the segments through Cerebras strict JSON Schema output, validates their number, and renders layout locally. It does not recognize commands in raw dictation. Therefore it proves that translation plus deterministic rendering works on those fixtures, not that the proposed full parser is validated.
7. Streaming reproduced the quote loss. The other three streaming cases passed. Both atomic and streaming final normalization must be included in a quote repair.

## Updated recommendation

Start with a scoped quote-handling repair: remove the conflicting blanket prohibition from the relevant output contract, carry explicit output policy, and preserve intentionally requested quotes through atomic and streaming finalization. Do not globally remove compatibility normalization for unrelated custom/selection workflows or guess operation mode from arbitrary prompt text.

Keep the existing one-call Cerebras translation pipeline while testing the quote repair and semantic edge cases. Do not ship the tested focused prompt merely because its raw pass count is higher: it regressed a self-correction. Treat the full formatting parser as a later design option for provider-independent guarantees, requiring its own raw-input parsing and ambiguity tests.

The app remains unchanged. This evaluation has not tested real microphone transcription, arbitrary user dictations, every workflow, or production UI delivery, and measures no latency or throughput.

## Reproduce

Provide a key file through a secure prompt. Do not paste a key into the command or commit it. From the repository root:

```sh
docs/verification/2026-11-09-cerebras-spoken-edits/run.sh /path/to/temporary-key-file baseline
```

Available modes: `baseline`, `quotes-contract`, `prompt-focused`, `layout`, and `streaming`. Each saves its completed results to `results.jsonl` and skips already-recorded case keys. Use a new artifact directory/result file for an independent repeat. `python3 docs/verification/2026-11-09-cerebras-spoken-edits/evaluate.py` regenerates the fixture evaluation. Source hashes identify this evaluated checkout. The supplied temporary key file was deleted after testing.

Sources: [Cerebras chat-completions API](https://inference-docs.cerebras.ai/api-reference/chat-completions), [Cerebras structured outputs](https://inference-docs.cerebras.ai/capabilities/structured-outputs).
