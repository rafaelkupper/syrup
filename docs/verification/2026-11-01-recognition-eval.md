# Synthetic recognition evaluation

Vocabulary on and off produced identical hypotheses in all 120 paired comparisons. This establishes no vocabulary benefit on these fixtures. It does not establish that contextual strings never help real voices. Finalization performance comparisons remain inconclusive under substantial host load.

## Method

Measured on 2026-11-01, Mac16,7, 14 logical CPUs, macOS 27.0.1 build 26A434, Apple Swift 6.4.2. The standalone runner uses `swiftc -O -swift-version 6 -parse-as-library`. No application source, permissions, installed app, hotkeys, or clipboard were changed or exercised.

The manifest contains 24 invented sentences, 12 pt-BR and 12 en-US, with six target and six guard clips per locale. `say` generated 24 kHz, signed 16-bit WAVs at 175 words per minute. Each locale uses three voices. Portuguese uses Luciana, Eddy, and Flo. English uses Samantha, Eddy, and Flo. Clip durations are 2.54 to 4.13 seconds. The same nine-term vocabulary, the union of target terms, is supplied to both target and guard clips when enabled.

Five repetitions alternate paired on/off order. Clip order uses a fixed seed for each repetition. The trim sweep rotates the starting offset. Every run creates a fresh analyzer and collector, supplies `.volatileResults`, and uses the app's `AnalysisContext.contextualStrings[.general]` call before prepare/start. Models can remain warm in the system service between requests. The tool checks installed locales and downloads no speech assets.

WER is total word edits divided by total reference words after case and punctuation normalization. Accents remain significant. Term recall requires exact normalized token sequences. Guard excess counts vocabulary occurrences beyond the reference. Last-word retention requires the hypothesis's final token to equal the reference's final token. These are automatic scores against the written sentences, without human adjudication of the generated pronunciations.

## Vocabulary comparison

The table gives each side separately. Five repetitions produced the same WER in every repetition for each locale and option.

| Locale | Vocabulary | Runs | WER | Terms recalled | Guard excess occurrences |
| --- | --- | ---: | ---: | ---: | ---: |
| pt-BR | Off | 60 | 22.22% | 0/45 | 0 in 30 guard runs |
| pt-BR | On | 60 | 22.22% | 0/45 | 0 in 30 guard runs |
| en-US | Off | 60 | 20.83% | 5/45, 11.11% | 0 in 30 guard runs |
| en-US | On | 60 | 20.83% | 5/45, 11.11% | 0 in 30 guard runs |

Without trimming, target WER was 100/260 word edits for pt-BR and 90/220 for en-US per side. Guard WER was 10/235 and 10/260. The terms cause observable errors, so identical on/off output is not an accuracy-ceiling result. No guard vocabulary insertion was observed. This does not exclude insertions on other inputs.

## End-trim sweep

Vocabulary is on. Each offset has 120 runs, 24 clips times five repetitions. Recognition is fed offline here. Finalization therefore includes processing queued audio and must not be read as release latency.

| End removed, ms | Last word retained | Retained among 115 baseline-retained runs | WER | Offline finalization median, ms | Min to max, ms |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 115/120 | 115/115 | 21.54% | 59.3 | 42.5 to 130.7 |
| 100 | 115/120 | 115/115 | 20.00% | 57.9 | 41.8 to 125.7 |
| 200 | 115/120 | 115/115 | 21.03% | 56.3 | 42.8 to 146.3 |
| 300 | 115/120 | 115/115 | 21.03% | 56.9 | 42.0 to 82.8 |
| 400 | 115/120 | 115/115 | 20.00% | 54.7 | 40.3 to 110.6 |
| 500 | 105/120 | 105/115 | 20.51% | 54.5 | 40.9 to 75.7 |
| 600 | 85/120 | 85/115 | 22.56% | 53.9 | 39.3 to 69.8 |

The five baseline misses are transcription mismatches before trimming. The untrimmed WAVs have median trailing silence of 406.6 ms, range 183.1 to 454.1 ms, estimated by the last source sample above absolute amplitude 0.01. This threshold is not a voice activity detector. The 400 ms row does not establish safe removal of 400 ms of voiced audio. At 500 and 600 ms, retention falls below baseline. These are destructive cuts from the end of synthetic files, not measurements of the app's release-tail policy.

## Paced release-to-final transcript

Four clips, one target and one guard per locale, ran with both vocabulary options for five repetitions. All 40 runs retained the final reference word. The following ranges span individual runs, not confidence intervals.

| Locale | Vocabulary | Runs | Finalization median, ms | Min to max, ms | Setup median, ms | Setup min to max, ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| pt-BR | Off | 10 | 73.7 | 47.3 to 139.9 | 41.0 | 21.4 to 75.5 |
| pt-BR | On | 10 | 75.0 | 48.2 to 116.8 | 42.6 | 20.1 to 80.7 |
| en-US | Off | 10 | 57.4 | 44.8 to 110.6 | 54.2 | 27.1 to 134.1 |
| en-US | On | 10 | 65.0 | 44.0 to 103.9 | 50.9 | 24.9 to 54.9 |

Across both locales, off has median 67.4 ms, range 44.8 to 139.9 ms, and on has median 68.7 ms, range 44.0 to 116.8 ms, with 20 runs per side. The 1.3 ms median difference is smaller than the spread. This comparison is inconclusive as a speed claim. Feed duration exceeded retained audio duration by median 1.8 ms, range 0.1 to 5.5 ms. Thus the worker did pace the complete clip before release, rather than treating queued offline work as a release measurement.

## What limits these numbers

The timed release boundary is after feeding the last buffer and sleeping to its audio end. The clock stops only after `finalizeAndFinishThroughEndOfInput()` and result collection complete. WAV reads and scoring are outside finalization. Setup includes locale readiness, conversion, the diagnostic end-silence scan, context, prepare, and start. Paced feeding uses 20 ms buffers; `feedMinusAudioMs` records overshoot rather than assuming real-time scheduling succeeded.

A separate 80-run profile was excluded from every table. Its worker sample shows `SpeechAnalyzer.processInput`, `SpeechRecognizerWorker.processAudio`, and `EARSpeechRecognitionAudioBuffer.addAudioSampleData` making XPC calls. Concurrent process counters show the local speech-recognition service at 77.5% CPU. The source waits for the analyzer and result collector, rather than Python scoring, in the finalization interval. The exact service-internal finalization limiter was not isolated, so there is no defensible claim that it should run twice as fast or that a small on/off timing difference is real.

The host was busy with unrelated work. Initial load averages were 8.79, 12.20, and 13.81. During paced runs the one-minute load reached 80.44. No unrelated process was stopped. Alternation reduces order bias but cannot remove scheduling noise. The range is part of the result. Neither the offline trim medians nor the paced comparison supports a speedup claim.

Synthetic voices lack the user's accent, hesitation, mixed-language phrasing, microphone noise, capture boundaries, and real release timing. This tool measures recognition and finalization only. It excludes microphone capture, application release tail, translation, and clipboard or paste delivery. Real-voice accuracy and complete hotkey-to-output latency remain unverified. Consented private clips can be supplied later through `SYRUP_EVAL_PRIVATE_MANIFEST`.

## Reproduce and inspect

```sh
script/recognition-eval.sh generate
script/recognition-eval.sh run --repeats 5 --output .cache/recognition-eval/vocabulary-new.jsonl
script/recognition-eval.sh run --trim-sweep --vocabulary on --repeats 5 --output .cache/recognition-eval/trim-new.jsonl
script/recognition-eval.sh run --realtime --clips pt-01,pt-08,en-01,en-08 --repeats 5 --output .cache/recognition-eval/realtime-new.jsonl
script/recognition-eval.sh summary .cache/recognition-eval/realtime-new.jsonl
python3 -B -m unittest discover -s script/recognition-eval -p 'test_*.py'
```

New output paths are required. Existing results are never overwritten. The [tool usage](../../script/recognition-eval/usage.md) defines the manifest, timing, scoring, privacy rules, and all options. No private text is printed without `--show-text`. Raw private results require an external path and mode 0600.

Local ignored evidence is under `.cache/recognition-eval/` in the evaluation worktree. It includes `fixtures.json`, the three named JSONL matrices and their summaries, `runner-sample.txt`, `process-counters.txt`, and `provenance.json` with source and evidence hashes. Audio and raw hypotheses are deliberately absent from Git.

The three main matrices contain 1,120 passed runs and zero failed, timed-out, empty-hypothesis, or zero-final-segment runs. Two initial smoke attempts had eight readiness failures because `AssetInventory.status` initially reported supported despite installed models. Replacing that check with the app's installed-locale lookup fixed the smoke run, which then passed all four requests. Failed smoke runs were excluded from the main matrices.

Six focused tests passed. They cover edit distance and normalization, complete-term matching and guard excess, last-word scoring, failure/timeout summary counts, and private path/refusal behavior without text leakage. A separate successful private-path test used a copied synthetic clip, kept its hypothesis off the console, verified a 0600 result file, and removed the temporary fixture. A forced watchdog test exited 1 and retained a `timedOut` row. These were control checks, not observations of real private content. Shell syntax, Swift 6 typechecking, and `git diff --check` passed. App unit tests, physical microphone capture, and app end-to-end checks were unrun because the application was unchanged.

Whisper was omitted under the task's cost exception. `project.yml` specifies WhisperKit from 1.1.0. The estimated cold build, model download, and calibration cost exceeds this native runner's setup. The app selects a 626 MB Whisper model, while this runner reuses installed Apple assets and builds with a single `swiftc` call. No Whisper build or download was attempted. `--engine whisper` fails explicitly and downloads nothing. No Whisper accuracy or timing claim is made.
