# Speech models and spoken edits, 2026-11-02

Personal identifiers and machine paths in this record use illustrative placeholders.

Measured on Mac16,7, macOS 27.0.1, FluidAudio 0.18.0. Clips are the 24 synthetic `say` clips in `script/recognition-eval/clips.json`, 12 per locale, plus one synthetic long clip per locale made by joining them (75 s English, 81 s Portuguese). No real voice was tested. Real accuracy may differ, in either direction.

## Accuracy and wait after release

WER is word errors over reference words. Short clips ran twice with identical word errors. The wait is release to final transcript on the long clip, paced in real time, two runs on an idle Mac.

| Model | Short en | Short pt | Long en | Long pt | Wait en, ms | Wait pt, ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple | 20.8% | 22.2% | 17.2% | 21.2% | 97, 97 | 89, 88 |
| Parakeet v3 | 4.2% | 13.1% | 4.2% | 9.1% | 267, 274 | 289, 288 |
| Nemotron Streaming 3.5, multilingual 2240 ms | 14.6% | 36.4% | 9.9% | 13.1% | 41, 53 | 60, 57 |
| Parakeet Unified EN, int8 70_13_13 | 6.2% | n/a | 4.7% | n/a | 43, 45 | n/a |
| Canary 180M Flash, Core ML int8 | 12.5% | n/a | 16.1% | n/a | 104, 102 | n/a |

Published FLEURS figures for Nemotron are better (6.14% pt, 8.76% multilingual en), on different audio. Nemotron returned nothing for one short Portuguese clip; the pipeline falls back to Apple then.

## How the bars are set

Accuracy uses the mean of a model's WER values above: 5 at or below 5%, 4 at or below 10%, 3 at or below 20%, 2 at or below 30%, otherwise 1. Speed uses the mean wait: 5 at or below 75 ms, 4 at or below 150 ms, 3 at or below 225 ms, 2 at or below 300 ms, otherwise 1. Canary is scored on English alone, as Parakeet Unified is. Every model here waits under a third of a second, so speed differences are small in practice. The bars do not show how often live text updates: about every 2 seconds for both streaming models.

## Choices the numbers made

- Nemotron multilingual and Latin matched on short clips (36.4% pt, 14.6% en), so Syrup uses multilingual: one download for every language. 1120 ms was no better on Portuguese (40.4%), so it uses the upstream recommended 2240 ms.
- Without leading silence Nemotron dropped opening words ("Vamos comprar" became "comprar"). 300 ms of silence restored them in the three tried clips that had lost words, so `NemotronBackend` feeds it first.
- Both streaming models returned empty text for 4 s of silence and for low noise, so they need no speech gate.

## Sizes and languages

The requested figures, 716 MB, 697 MB, 208 MB, and 28 languages, are Handy's catalog entries (`cjpais/Handy`, `src-tauri/src/catalog/catalog.json`). Handy ships GGUF Q8_0 files: 751,094,240, 731,357,568, and 218,447,648 bytes, which are 716, 697, and 208 MiB. Syrup runs Core ML builds of the same NVIDIA models instead, which are 640 MB (Nemotron multilingual 2240 ms), 595 MB (Parakeet Unified int8 streaming), and 256 MB (Canary int8). Running the GGUF files would need a new ggml runtime.

Nemotron's 28 languages are NVIDIA's: the model card lists 32 locales as transcription-ready or broad-coverage, 28 distinct languages, and 8 more as adaptation-ready, which need fine-tuning. Handy uses the same 32 locales. FluidAudio's metadata holds about 100 prompt codes, which Syrup does not offer. Only English and Portuguese were measured here.

## Canary 180M Flash

The earlier search missed two Core ML conversions. Syrup uses `aufklarer/Canary-180M-Flash-CoreML` at revision `ca44e0f5d816a2362cf01f7316e4932c86aafef6`, CC-BY-4.0, int8, with a 10-second encoder window. The other, `smdesai/canary-180m-flash-coreml`, is 369 MB with a different graph. Syrup's code computes the features and runs the decode loop, so no new library ships. The bundle's published FLEURS English WER is 7.40% on utterances under 10 s.

One 9.8-second window of the long English clip first decoded to nothing: the model emitted end-of-text as its first token. Splitting that window at its middle pause recovered the speech, and the long clip's WER went from 22.4% to 16.1%. The remaining errors are spellings of names and terms.

Canary can translate between its four languages. Syrup uses it only to transcribe, with the workflow language as both source and target.

## End to end through Syrup's code

A separate `org.syrup.SyrupUIVerify` host ran `SpeechModelCatalog.live` with temporary storage, on the real download, load, `StreamingTranscriber`, and remove paths.

| Model | Download and load | Result | Delete |
| --- | ---: | --- | --- |
| Parakeet Unified EN | 42 s | en-01 right, twice, with partials | Folder gone, state not downloaded |
| Nemotron Streaming 3.5 | 32 s | en-01 and pt-08 right, twice each, with partials | Folder gone, state not downloaded |
| Canary 180M Flash | 23 s, progress 0 to 100% | en-01 right; the 75 s clip in 2.1 s of processing | Folder gone |

A second run after the language change repeated all three: downloads, en-01 right on each, Nemotron's pt-08 right, and every folder gone after Delete. FluidAudio's progress for Nemotron and Parakeet Unified stopped reporting at 90% and 50% before Ready.

Home, Recording with all five models, and Privacy rendered there with seeded stats and were inspected, Home and Recording in light and dark.

## Spoken edits on a real provider

17 invented sentences ran through `codex exec` with the real instructions on, in the app's prompt shape. All 17 were right: 3 self-corrections, 2 real contrasts kept ("I said three, not four"), 3 lists, 2 quotes, 2 paragraphs, 1 line break, and 4 cases where a command phrase was content ("please add a new paragraph to the contract"). That is one run per sentence on one provider, so it shows the instruction works, not a rate. Apple On-Device could not run because this Mac's model reports `modelNotReady`. OpenAI-compatible endpoints and local models were not tried, and smaller models may do worse.

## Tests

600 Swift tests in 75 suites passed, and 10 evaluation tool tests passed. The universal Release build succeeded after Canary's Float16 read was made to compile on Intel. Nine deliberate breaks, applied together in a temporary copy, each made tests fail: selected text getting spoken edits, formatting following the wrong setting, deleting the shared folder, counting revisions, ignoring the stats setting, keeping long samples in words per minute, the wrapper quote guard, streaming partials not reaching the model, and running before load.

## Not checked

- A real microphone, real dictation, or the production app. Live text timing, real-voice accuracy, and voiced-time words per minute have only fake-clock or synthetic evidence.
- Clicking the new controls, a failed or interrupted download, and app icons or names for apps not installed, which show the bundle identifier.
- Intel Macs, where these models are hidden; the build compiled but was not run.
