# Spoken edits, round two: a real dictation that failed

Personal identifiers and machine paths in this record use illustrative placeholders.

Verified on 2026-11-10 against Cerebras `gpt-oss-120b` through Syrup's real provider code.

## What happened

the maintainer dictated, in Portuguese, a sentence with a hesitation, a self-correction ("dois, não, três testes"), "nova linha", "abre aspas ... fecha aspas", a trailing "e é..." and "ponto final". Syrup kept "two, no, three", kept the fillers, and wrote "is a period". The run used the Translate workflow with both spoken-edit toggles on, so the misses were the model's reading of the prompt.

## Result

40 synthetic fixtures (yesterday's 22 plus 18 new ones built around the failure), scored on what Syrup delivers.

| Feature | Old prompt (3 runs each) | New prompt (4 runs each) |
|---|---:|---:|
| Plain translation and fillers | 12/15 | 20/20 |
| Self-corrections | 23/27 | 36/36 |
| Line breaks, paragraphs, lists | 18/18 | 24/24 |
| Spoken punctuation | 8/9 | 12/12 |
| Quotes | 9/15 | 20/20 |
| Literal mentions | 20/21 | 26/28 |
| Several commands in one dictation | 1/15 | 9/20 |
| **Total** | **91/120 (76%)** | **147/160 (92%)** |
| Request time, median / p90 / max | 369 / 482 / 2300 ms | 391 / 523 / 791 ms |

## What changed

- **Self-corrections** now say the input is dictated speech, drop hesitation sounds, add a bare "no" example ("two, no, three tests"), name more cues ("actually", "sorry", "scratch that", "digo", "aliás", "ou melhor"), and say that a "no" that answers or negates is content.
- **Formatting commands** add "open quote ... close quote" / "abre aspas ... fecha aspas", and spoken punctuation: period / full stop / ponto final, comma / vírgula, question mark / ponto de interrogação, exclamation mark / ponto de exclamação. Quoted words are translated like the rest.
- **A closing line** tells the model to write the whole result in the target language. Without it, a revision left Portuguese untranslated in 6 of 294 runs; with it, 0 of 168.
- `ModelOutputNormalizer.requestsQuotes` also recognizes "open quote(s)", "close quote(s)", "abre aspas" and "fecha aspas".

## What still fails

- **A fragment left hanging before a command.** "e é... ponto final" comes out as "And that's a period." or "And that's the end." in 3 of 4 runs, and two extra fixtures built to test it ("... e aí... nova linha", "... and, uh, so the... new paragraph") failed 8 of 8. The words are real words, and the model keeps them. A rule written for this case made other results worse and was dropped.
- **Long dictations with several commands** remain the weak spot: 9 of 20. Besides the hanging fragment, "nova linha" sometimes becomes a blank line.
- **A literal mention of "new line"** still becomes a line break in 2 of 4 runs, as before.
- Two fixtures without commas ("cinco não seis cadeiras") were removed: they also read as "five, not six", so they can't be scored.

## What was tried and rejected

- **Higher reasoning effort.** `reasoning_effort: high` scored 110/120 against 104/120 at medium on an intermediate prompt, but the long sentence took 2 to 5 seconds and once returned nothing after 11 seconds. Results are in `effort/`. Not adopted.
- **Temperature 0** scored 142/168 against 140/168 at 0.3 on an intermediate prompt, with the same failures repeated on every run. Not adopted.
- **Applying commands before the model.** A probe gave the model text with the line break and quotes already in place; it flattened the line break in at least 19 of 24 runs. Deterministic layout would need the model to translate separate segments that Syrup rejoins, as planned in `plans/syrup/2026-11-09/spoken-formatting-repair.md`.

## Method and limits

- `baseline/` and `final/` were produced by `../2026-11-09-model-comparison/run.sh cerebras gpt-oss-120b N` with `ARTIFACTS` set to each folder, which compiles Syrup's `PromptBuilder` and `OpenAICompatibleTransformer`. `effort/` and the intermediate prompt comparisons used `direct.py`, which sends the same prompt and temperature straight to the API. Intermediate prompt runs were not kept.
- The exact transcript Parakeet produced is not known; history was not read. The fixtures use the maintainer's typed version, a punctuated version, and an unpunctuated one.
- Several prompt examples resemble fixtures, so the new fixtures overstate how well the prompt generalizes. Synthetic text only; real speech is untested. Apple On-Device and Qwen were not rerun; Apple never receives these instructions.

Score a folder with `python3 docs/verification/2026-11-10-spoken-edits-round2/evaluate.py <folder>`.
