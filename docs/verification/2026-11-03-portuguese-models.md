# Portuguese speech models, 2026-11-03

Personal identifiers and machine paths in this record use illustrative placeholders.

the maintainer asked for the best Portuguese models with at most 500 ms of waiting after release and under 1 GB. Parakeet Ultra was the best that met both limits. It is a post-training of Parakeet v3 that FluidAudio 0.18.0 already loads (`AsrModelVersion.ultra`).

## Method

Real voices: the first 200 Brazilian Portuguese test clips of FLEURS (`FluidInference/fleurs-full`, `pt_br`, CC-BY-4.0), 5 to 37 seconds each and 4,867 reference words. There were also three clips of 61, 65, and 79 seconds made by joining FLEURS clips with 300 ms gaps. WER lowercases, strips punctuation, and keeps accents. FLEURS writes numbers as digits, so a model that spells them out is charged for it. Mac16,7, macOS 27.0.1, one run per clip, models in scratch storage.

The wait is the time to decode a clip after the whole of it is in hand. Parakeet-family models in Syrup decode up to 60 seconds at release, so their wait is the "at release" figure. Models with a 15- or 30-second window can decode earlier windows during recording, which leaves only the last window as the wait. Nemotron Streaming's wait is its `finish()` call.

## Results

| Model | Size | WER, 200 clips | Wait, median / p90 / max | WER, long clips | Long clips, at release | Last window only |
| --- | --- | ---: | --- | ---: | --- | --- |
| Parakeet Ultra | 632 MB | **4.15%** | 57 / 107 / 138 ms | 4.43% | 368, 226, 293 ms | 43, 38, 101 ms |
| Whisper large-v3 turbo (WhisperKit, 626 MB variant) | 626 MB | 4.07% | 904 / 1,076 / 2,018 ms | 23.96% | 2,956 to 3,334 ms | same |
| Parakeet v3 (current) | 470 MB | 5.05% | 55 / 104 / 137 ms | 4.17% | 373, 221, 289 ms | 44, 37, 106 ms |
| Parakeet Redux | 220 MB | 5.26% | 81 / 155 / 217 ms | 6.51% | 592, 372, 467 ms | 66, 59, 152 ms |
| Nemotron Unified ASR 0.6B, int8 offline | 630 MB | 5.36% | 67 / 117 / 194 ms | 6.25% | 338, 327, 410 ms | 70, 60, 67 ms |
| Canary 1B v2, int4 | 636 MB | 6.10% | 1,330 / 2,290 / 4,055 ms | 7.55% | 6.8 to 8.2 s | 1,227 to 1,637 ms |
| Parakeet TDT 0.6B Portuguese fine-tune (`yuriyvnv`, OpenVoiceOS int8 Core ML) | 614 MB | 6.60% | 70 / 128 / 222 ms | 5.47% | 364 to 463 ms | 67 to 79 ms |
| Apple SpeechAnalyzer | built in | 6.80% | not comparable offline | 7.81% | 94, 138, 174 ms paced | n/a |
| Nemotron Streaming 3.5 | 640 MB | 8.49% | 31 / 39 / 120 ms | 7.81% | 28 to 32 ms | same |

Ultra against v3 on the 200 clips: 202 word errors against 246, better on 38 clips, worse on 11, and equal on 151. The long clips hold about 600 words, where the two differ by 2 errors. That difference is within noise.

## Excluded without a local run

- Qwen3-ASR 0.6B: the int8 Core ML build is about 1.3 GB (373 MB encoder, 598 MB decoder, 311 MB embeddings), and FluidAudio 0.18.0 has no runner for it.
- Cohere Transcribe: the int8 encoder alone is 1.8 GB.
- Nemotron Unified fp16: about 1.2 GB. Its int8 build, measured above, lost accuracy on French in FluidAudio's conversion check.
- Voxtral, Granite Speech, Phi-4 Multimodal, and Canary-Qwen: several GB.
- Moonshine, SenseVoice, and Kyutai STT have no Portuguese model.

## Notes

- Whisper turbo was the most accurate on short clips but waited 0.9 seconds at the median, and it lost text on the long clips. It fails the 500 ms limit.
- Canary 1B v2 waited more than a second per window as FluidAudio runs it.
- The Portuguese fine-tune was trained on Common Voice and OpenAI TTS speech. On FLEURS it did worse than the v3 model it started from.
- Redux needed several minutes to compile on first load.
- These are read sentences by many speakers. Dictation, accents, and noise may change the order, so real dictation should confirm the result.
