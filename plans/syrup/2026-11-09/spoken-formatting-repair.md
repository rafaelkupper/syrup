# Spoken formatting repair

## Goal

Make the documented spoken formatting commands produce reliable layout with Apple On-Device while retaining translation, self-corrections, and the user's meaning.

## Context

The current Apple path receives a free-form instruction combining translation, self-correction, and formatting. Real-model tests reproduced missing line breaks and paragraphs. The output contract also says "no quotes", while another instruction requests quotes; ModelOutputNormalizer removes a complete enclosing quote pair. Simple self-corrections passed, so the user's specific self-correction failure remains undiagnosed.

Two prompt-only revisions and a single-string structured-output experiment introduced language, content, or layout errors. They are not suitable fixes.

A 2026-11-09 prototype instead supplied pre-separated text segments, obtained their translations in one structured response, and rendered separators and quotes locally. Its six controlled cases produced the intended newline, paragraph, quoted phrase, Portuguese-to-English translation, corrected recipient, and literal mention of a paragraph. The prototype did not parse raw dictation and is not an end-to-end implementation or a reliability benchmark. Code and exact output are in `/private/tmp/syrup-format-layout-20261109/`.

## Proposed implementation

1. Introduce a small spoken-document representation in `Sources/Translation/`: text segments plus explicit line-break, paragraph, quote, and list structure. Add a conservative parser for the documented English and Portuguese commands. Ordinary prose such as "add a new paragraph to the contract" must remain text. Command recognition and quote/list extent are acceptance requirements, not solved by the prototype.
2. Pass the speech-edit options explicitly from `AppSettings.runConfiguration` through `RunConfiguration` and the provider factory. Apply the parser only to voice Translate workflows with formatting enabled. Avoid inferring operation mode from substrings of the instruction. Keep custom, selected-text, revision, and disabled-option semantics intact.
3. For the Apple path, translate all text segments together in one FoundationModels request, returning structured segments. Keep context across segments. Validate segment count/order and reject missing or empty content rather than silently dropping it. Keep FoundationModels-specific types inside the Apple provider.
4. Render the stored layout locally after translation. This makes line breaks and quote placement independent of free-form model generation. Use the same final renderer for normal, early-result, and streaming completion paths. Do not send provisional structured output directly to an editor; only expose content whose segment identity and layout are known.
5. Replace the conflicting blanket "no quotes" instruction with wording that prohibits added wrapper quotes but permits intentional quotes. Preserve semantic quotes in normalization. Cover `AppleOnDeviceTransformer`, `ModelOutputNormalizer`, and `AppState.streamAndDeliver` so a later normalization pass cannot strip them again.
6. Keep self-correction a semantic model task with focused instructions and tests. Do not delete arbitrary text around "no", "sorry", or "I mean" with regexes. Test the final speech transcript boundary as well as model input/output before claiming the user's self-correction failure fixed. Consider a separate correction pass only if focused evidence proves it necessary.

## Constraints

- Keep the common Transcriber and TextTransformer boundaries and keep engine types private.
- Prefer one model request per transformation. The prototype used one request for all text segments; no latency improvement is claimed or measured.
- No new permissions, remote processing, or user-content logging.
- Preserve existing disabled-option, custom, selection, revision, and cancellation behavior.
- Leave unrelated shared-checkout changes intact.
- This document is a plan. No production code, running app, or user settings were changed.

## Done-when

- Raw dictated text, including punctuation variants and mixed English/Portuguese commands, passes the parser-to-provider-to-final-output tests.
- Newline versus paragraph, bullets versus numbered lists, intentional quotes, and ordinary prose mentioning those words are distinguished correctly.
- Names, numbers, output language, glossary terms, and uncorrected content remain intact.
- Self-correction cases include replacement of names, dates, times, numbers, multiword phrases, and ordinary negation. No claim that all arbitrary self-corrections are solved.
- Atomic, streaming completion, and pause-result delivery produce the same intended structure; cancellation never delivers partial structured data as final text.
- Focused deterministic tests and the isolated application suite pass, followed by controlled real-Apple-model and synthetic-speech tests. Report unrun manual microphone checks separately.

## Cerebras evaluation changes the priority

The requested `gpt-oss-120b` model completed 88 live synthetic evaluation requests. Current self-correction, newline, paragraph, and list fixtures worked; quote normalization is a definite application bug, and a literal mention of "new line" was misclassified once. A focused prompt rewrite improved some cases but introduced a self-correction error. The full parser remains unimplemented and is no longer recommended as the first change for the Cerebras path. Start with a scoped quote-policy repair and its atomic/streaming tests, then expand semantic fixtures before deciding whether a parser is needed. See [the full evaluation](../../../docs/verification/2026-11-09-cerebras-spoken-edits/report.md). Production code and settings remain unchanged.
