# Recognition evaluation

Run on macOS 26 or newer with Xcode command-line tools and Python 3.10 or newer. Install pt-BR and en-US SpeechTranscriber assets through Syrup first. The tool reads installed assets and requests no speech, microphone, or Accessibility permissions. Parakeet engines also need Apple silicon and, on first use, network access.

Generate 24 synthetic clips and compare recognition with vocabulary on and off. The committed manifest uses invented sentences and fixture names, including Mirela and Nairumi; these are not records of people or user dictation. See [the original fixture report](../../docs/verification/2026-11-01-recognition-eval.md).

```sh
script/recognition-eval.sh generate
script/recognition-eval.sh run --repeats 5 --output .cache/recognition-eval/vocabulary.jsonl
script/recognition-eval.sh run --trim-sweep --vocabulary on --repeats 5 --output .cache/recognition-eval/trim.jsonl
script/recognition-eval.sh run --realtime --clips pt-01,pt-08,en-01,en-08 --repeats 5 --output .cache/recognition-eval/realtime.jsonl
script/recognition-eval.sh run --engine apple,parakeet-v3,parakeet-ultra,parakeet-redux --vocabulary off --repeats 5 --output .cache/recognition-eval/engines.jsonl
script/recognition-eval.sh run --engine parakeet-v3 --vocabulary both --aliases script/recognition-eval/apple-mishearings.json --boost-rescue off --repeats 5 --output .cache/recognition-eval/boost.jsonl
script/recognition-eval.sh summary .cache/recognition-eval/realtime.jsonl
python3 -B -m unittest discover -s script/recognition-eval -p 'test_*.py'
```

Choose a new output filename for each run. Existing results are never overwritten. Audio, the optimized Swift binary, fixture voice/hash metadata, and raw results stay in `.cache/recognition-eval/`, which Git ignores. Summaries contain metrics only. Add `--show-text` to print hypotheses explicitly. A failed run exits nonzero and preserves completed rows. Each request has a 120-second watchdog, configurable with `--timeout-seconds`.

`EvalClip` has `id`, `wav`, `locale`, `reference`, `expectedTerms`, and `group`. The group is `target` or `guard`. The built-in vocabulary is the union of expected terms from the entire manifest, including unselected clips, capped at 100 to match the app. Both groups receive the same vocabulary. `--vocabulary both` alternates paired order between repetitions. Clip order uses a fixed seed per repetition. Trim sweeps rotate the starting offset between repetitions.

`--trim-end-ms N` removes N milliseconds from the source WAV. `--trim-sweep` runs 0, 100, 200, 300, 400, 500, and 600 ms. WER uses Unicode words, ignores case and punctuation, preserves accents, and removes apostrophes. Term recall matches complete normalized token sequences. Guard excess counts vocabulary occurrences beyond those in the reference. Last-word retention requires the hypothesis to end with the reference's final normalized word. A missing expected term gives null recall, rather than a perfect score.

The runner converts each retained clip to the analyzer format and feeds 20 ms buffers. Setup includes locale lookup, conversion, context, preparation, and start. WAV reading, the diagnostic end-silence scan, and prefix construction are outside setup and included in wall time. Finalization ends after both `finalizeAndFinishThroughEndOfInput()` and result collection complete. Without `--realtime`, this includes recognition of the queued clip. With `--realtime`, feeding sleeps to each buffer's end, including the last buffer, and finalization starts at simulated release. `feedMinusAudioMs` exposes scheduling overruns. This excludes microphone capture, release-tail policy, translation, and delivery. `trailingSilenceMs` estimates the retained source's end margin using the last sample above absolute amplitude 0.01. It is not a voice activity detector.

For Apple, add `--prefer-fast-results` to compare `.fastResults` with the default accurate mode. Realtime rows report `partialMatchAfterSpeechMs` and `partialMatchBeforeReleaseMs` when a live partial first matches the final transcript before simulated release. Matching trims surrounding whitespace and then compares UTF-8 bytes. A missing value means no matching partial was observed before release; offline runs do not measure readiness. The summary counts matches within 300, 600, and 1000 ms after the amplitude-based end-of-speech estimate. These counts do not include the additional 300 ms of transcript stability required by early transformation. Raw partial strings remain in memory only and are not written to the output.


For a finalized offline prefix comparison, run the same clips, vocabulary, and recognition mode at each offset and at realtime release. `--prefix-after-speech-ms 300` or `600` retains audio through that offset after the last source sample above amplitude 0.01. Missing silence is filled with zeros in memory; source files are unchanged. `--end-silence-ms 1500` pads the realtime reference to at least 1.5 seconds after speech. Prefixes are offline Apple only; neither option combines with trimming. `speechEndMs` records the measured source speech endpoint. `wallMs` covers the entire request including file reading, setup, feeding, finalization, and result collection. Add `--whole-buffer` to feed the converted offline prefix in one buffer, matching the app's coalesced pause snapshot; otherwise the runner uses 20 ms pieces.

```sh
script/recognition-eval.sh run --vocabulary off --repeats 3 --end-silence-ms 1500 --realtime --output .cache/recognition-eval/release.jsonl
script/recognition-eval.sh run --vocabulary off --repeats 3 --whole-buffer --prefix-after-speech-ms 300 --output .cache/recognition-eval/prefix-300.jsonl
script/recognition-eval.sh run --vocabulary off --repeats 3 --whole-buffer --prefix-after-speech-ms 600 --output .cache/recognition-eval/prefix-600.jsonl
cat .cache/recognition-eval/release.jsonl .cache/recognition-eval/prefix-300.jsonl .cache/recognition-eval/prefix-600.jsonl > .cache/recognition-eval/pause-combined.jsonl
script/recognition-eval.sh compare-pauses .cache/recognition-eval/pause-combined.jsonl
```

Repeat with `--prefer-fast-results` for fast recognition. For measurements, interleave modes and prefix/release order across rounds. `compare-pauses` pairs clip, locale, mode, vocabulary, and repetition; separately invoked one-repeat rounds must receive distinct repetition values before combining. It rejects duplicate or missing references, compares trimmed UTF-8 without Unicode normalization, retains failures and empty results in the denominator, and reports request latency by clip length. This measures transcript reuse eligibility, not a provider speedup or a microphone hit rate.


For consented real-voice clips, place a manifest and WAVs outside every Git worktree. Relative `wav` paths resolve from that manifest. The tool requires an external output path and creates a new results file with mode 0600.

```sh
SYRUP_EVAL_PRIVATE_MANIFEST=/absolute/private/clips.json \
  script/recognition-eval.sh run --realtime --output /absolute/private/results.jsonl
```

Private content is never printed by default. Raw external results contain hypotheses and must remain private. No generated audio or private results belong in a commit. The tool does not read app defaults, secrets, recordings, or history.

`--engine` takes one engine or a comma-separated list: `apple`, `parakeet-v3`, `parakeet-ultra`, `parakeet-redux`, `parakeet-unified`, `nemotron-latin-2240`, `nemotron-multi-2240`, `nemotron-multi-1120`, and `canary-180m`. Streaming engines receive 20 ms pieces, as Syrup feeds them. `canary-180m` compiles Syrup's own `CanaryModel.swift` and `SpeechSegmenter.swift` with `swiftc` and cuts audio into 10-second windows the way `CanaryTranscriber` does. With several engines, each clip runs once per engine back to back, and the engine order reverses on odd repetitions, so warmup and drift favor no engine. Each engine keeps one warm worker for the whole run. Rows carry their engine, and the summary groups by it.

The Parakeet engines run [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.18.0 from the SwiftPM package in `parakeet/`, built into `.cache/recognition-eval/parakeet-build/`. The first run of each version downloads its Core ML model from Hugging Face into `.cache/recognition-eval/models/`: about 480 MB for v3, 630 MB for Ultra, and 220 MB for Redux. The tool never reads or writes Syrup's Application Support or FluidAudio's default model cache. Loading a model from a new path compiles it for the Neural Engine, which took 9 to 14 seconds once per path on the measuring Mac. Redux took several minutes, because of its 2-bit weights. Each worker loads its model and runs one 1-second silent warm-up decode before the first request, reported as `loadMs` and `warmupMs`. The runner passes the clip locale's language subtag as FluidAudio's script filter. Setup covers 16 kHz mono conversion, the end-silence scan, and decoder-state creation. Feeding appends 20 ms chunks to an in-memory buffer, sleeping to each chunk's end with `--realtime`. Finalization is one whole-clip decode from simulated release, so offline and paced finalization measure the same work.

With `--vocabulary on` or `both`, the Parakeet runner adds FluidAudio's CTC vocabulary boosting after the decode. On first use it downloads `parakeet-ctc-110m`, about 98 MB, into `.cache/recognition-eval/models/`. It tokenizes the manifest's terms with that model's tokenizer, spots them with `CtcKeywordSpotter`, and rescores the transcript with `VocabularyRescorer.ctcTokenRescore`, the steps of `VocabularyBoostingSession.rescore` without its fixed use of FluidAudio's default model directory. `--aliases PATH` sends a JSON object of term to misheard forms as the terms' aliases. `apple-mishearings.json` holds Apple's own misrecognitions of each term in these clips, limited to forms that contain letters. `--boost-rescue` selects FluidAudio's spotter-anchored rescue pass: `default`, `floors` for `VocabularyBoostingSession.itnDefaultConfig`, or `off`. Rows report the rescore time as `boostMs`, and finalization includes it. Apple ignores both options.

`--engine whisper` exits with an explicit unsupported message. It downloads nothing. Syrup itself no longer depends on WhisperKit. Supporting it requires a WhisperKit build, a tool-owned model download, and calibration of its batch finalization against Apple's incremental analysis. A Whisper comparison and real-voice accuracy remain unrun.
