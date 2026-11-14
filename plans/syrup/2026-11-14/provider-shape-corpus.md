# Provider-shape corpus and property tests for the stream parser and error handling

## Goal

Test the OpenAI-compatible stream parser and the transformer's error handling against what providers actually send, not shapes the code assumes, and fix the two round-11 rules this exposes:

1. Numbers and true/false values in a delta count as stream progress, though nothing was generated.
2. A temperature rejection is remembered for the session whenever the rejection body contains "temperature" anywhere, and in a stream it is remembered as soon as the retry's headers arrive, before any answer.

Merge into the local `main` only after a three-delegate review finds no regression.

## Context

- Step 4 of the plan Rafael approved on 2026-11-14 ("OK, do it"). Steps 1 to 3 and the partial-download Delete are merged at `f57d9e7`.
- Round 11 reviewers: "only remember rejections that name `temperature` structurally (`error.param`, or a message matching a narrower pattern), and in the streaming path remember only after the first answer delta or successful completion"; and "a 400 that mentions temperature for another reason, whose retry also fails ... is not remembered. No test pins this."
- The stream parser's rules (`OpenAISSEParser`, `JSONFieldValue`) were changed in steps 1 and 3 of this plan series; each change was checked against hand-built shapes from documentation prose.

## Constraints

- AGENTS.md hard rules; Swift 6, Swift Testing; `script/ci_test.sh` must pass.
- Corpus entries are copied from official documentation or published API references, with the URL and retrieval date beside each; no invented shapes in the corpus. Hand-built cases stay in their own tests, labeled as such.
- Tests never touch the network; the corpus is checked in.
- Red first for each rule change; a deliberate break in each change fails a test.
- Network access only to public documentation, anonymously.

## Done when

1. A corpus file holds documented stream chunks and error bodies for OpenAI, OpenRouter, Mistral, Groq, DeepSeek, vLLM, LM Studio, and Ollama (whichever publish them), each with source URL, retrieval date, and the documented meaning (answer text, reasoning, tool call, keepalive, usage, error kind).
2. A test runs every stream entry through `OpenAISSEParser` and checks answer text and progress; another runs every error entry through the transformer's rejection and error mapping.
3. Property tests generate deltas from a grammar of labels, empty and non-empty strings, nulls, numbers, flags, text parts, and reasoning parts, and check: answer text is the joined text parts; progress holds exactly when some generated string is non-empty; nothing crashes.
4. Numbers and flags are not progress (red first).
5. A temperature rejection is remembered only when the error names `temperature` structurally, and only after the first answer delta in a stream or a decoded completion in a non-streamed request; a mention for another reason is retried once but not remembered, and that is tested (red first).
6. ARCHITECTURE.md describes the rules; a three-delegate review finds no regression before merge.

## Progress

- 2026-11-14: plan written; branch `provider-shape-corpus` from `main` at `f57d9e7`.
- 2026-11-14, red first (hand-built cases, labeled in the tests): a delta holding only a number or only a flag counted as progress; a rejection mentioning temperature for another reason was remembered (streamed and not); a streamed retry was remembered before its answer started, though its stream then failed. A mention whose retry fails was already not remembered; it is now pinned.
- 2026-11-14, fixes: numbers and flags are not generated text; `namesTemperatureAsRejected` (`param` is `temperature`, or a message names temperature with "unsupported", "not supported", "does not support", or "only the default") decides what is remembered, and the memory is written when the retry's first delta is passed on (streamed) or its reply decodes (not streamed). Any mention still earns the one retry. The three red tests pass; the transformer, parser, and streaming suites pass (66 tests).
- 2026-11-14, property tests: `OpenAISSEPropertyTests` generates 2,000 deltas from four fixed seeds and checks answer text and progress against the rule written out independently in the test; it requires over 100 progress cases, over 100 non-progress cases, and over 50 with answer text per seed. Deliberate breaks, each alone, all caught: numbers counting, reasoning parts ignored, labels counting, and `role` counting (property test); remembering any mention, remembering at the retry's headers, and never remembering (transformer tests). Not tested: a non-streamed retry whose reply then fails to decode.
- 2026-11-14: corpus research delegated; it returns documented chunks and error bodies with sources.
- 2026-11-14, corpus: the research delegate fetched documentation for all eight providers and returned 47 entries, each sliced by script from a fetched page, with source and nearby text. I checked three against their pages myself (OpenRouter's `: OPENROUTER PROCESSING` keepalive and its mid-stream error chunk, and Mistral's flat error body); all matched. Findings: no provider publishes a temperature rejection body; Mistral prints no streamed thinking chunk (prose and SDK code only); Groq, LM Studio, and Ollama publish no raw OpenAI-compatible stream chunk; several examples are pretty-printed, unprefixed, or not valid JSON as printed.
- 2026-11-14, `ProviderCorpus.swift` is generated by a script from that JSON, so no entry is retyped: 31 stream cases, 13 error cases, and 3 exclusions with reasons (an abridged example with a literal `...`, Python SDK printouts, and Ollama's native NDJSON stream). Each case notes any change made to put it on the wire (`data: ` added, pretty JSON compacted, the vLLM pages' trailing commas removed, documented `delta.tool_calls` values wrapped in a chunk). Expected answer text, progress, and ending come from what each page says the example carries; for the two whole-stream examples, the answer is their documented content pieces joined.
- 2026-11-14, `ProviderCorpusTests`: every documented stream parses as documented, no documented error reads as a temperature or streaming rejection, and each error shown with a status maps to its error (`httpStatus`, `rateLimited`, or, for OpenRouter's non-streamed reply whose choice ends in `finish_reason: "error"` with partial output, `providerReportedError`) after exactly one request, streamed and not. The corpus found no new parser bug. Deliberate breaks of the parser, each alone, are caught by the corpus: ignoring mid-stream errors (4 cases fail), not recording `finish_reason: stop` (6), and reading SSE comment lines as data (7). The existing temperature tests are labeled as hand-built. To call them from the tests, `rejectsTemperature` and `rejectsStreaming` are no longer private.
- 2026-11-14: `script/ci_test.sh` passed: boundary check, production build with no source warnings, 825 tests in 115 suites. Committed; the three-delegate review runs before any merge.
