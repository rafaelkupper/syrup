# Speech engine comparison

Personal identifiers and machine paths in this record use illustrative placeholders.

Parakeet v3 recognized far more domain terms than Apple's `SpeechTranscriber` on the synthetic clips, and Apple made fewer errors on ordinary Portuguese. Neither engine wins every metric, so Apple stays the default and Parakeet v3 is an opt-in per workflow. Parakeet Ultra scored below v3 on every target metric and tied it on guard clips, so it gets no setting. Release-to-final latency at real-time pace showed no measurable difference between the engines on short clips. In the app, Apple's fast-results recognizer drives the live preview during a Parakeet run. Parakeet decodes a dictation of up to 60 seconds once at release, because cutting continuous speech into 15-second segments put a false sentence break at every cut. That removed all 13 inserted breaks on eight synthetic clips, but release-to-final past 15 seconds rose from 97 to 119 ms to 207 to 231 ms on a busy machine, and a one-hour dictation peaked 71 MB above the loaded model instead of 13 MB. Each decode first checks that its audio holds speech, which removed every hallucinated word from 50 synthetic noise clips and rejected none of 38 short, quiet, or whispered speech clips. FluidAudio makes the download 4.4 times as large, 25.5 MB against 5.8 MB, and adds about 0.17 seconds to the first launch of a new build. Glossary boosting through FluidAudio raised term recall but inserted a glossary term into an ordinary English sentence, so it is not used.

Which metric favors which engine:

- Target WER and term recall favor Parakeet v3 in both locales.
- Portuguese guard WER favors Apple, 4.26% against 12.77%.
- English guard WER favors Parakeet, 0% against 3.85%.
- Last-word retention on Portuguese favors Apple, 55 of 60 runs against 50 of 60.
- Release-to-final latency on 3- to 4-second clips favors neither. The gaps are smaller than the run-to-run spread. On 30 to 44 seconds Apple's default mode finished 22 to 70 ms before a whole-clip Parakeet decode.

## Method

Measured on 2026-11-01 on a Mac16,7 (Apple M4 Pro, 14 logical CPUs, 48 GB) running macOS 27.0.1 build 26A434 with Apple Swift 6.4.2. The Apple runner is unchanged. The Parakeet runner uses FluidAudio 0.18.0 at revision `e15287985625dbf544a343df679436789ffb03fb`, with the `parakeet-tdt-0.6b-v3` and `parakeet-ultra` Core ML models loaded through `AsrModels.loadLocal` on the Neural Engine. It passes the clip's language subtag as FluidAudio's script filter. No application source, installed app, permission, hotkey, microphone, or clipboard was used.

The clips are the 24 synthetic `say` sentences from the [recognition evaluation](2026-11-01-recognition-eval.md): 12 pt-BR and 12 en-US, six target and six guard clips per locale, 2.5 to 4.1 seconds each. Their SHA-256 hashes match the evaluation's `fixtures.json`. Each run used `--engine apple,parakeet-v3,parakeet-ultra --vocabulary off`. Every clip ran on all three engines back to back, and the engine order reversed on odd repetitions. Scoring is unchanged: WER over normalized words with accents significant, exact term-sequence recall, guard excess insertions, and final-word retention.

## Accuracy

Five repetitions gave 360 passed runs and no failed or timed-out runs. Every engine returned the same hypothesis for every clip in all five repetitions, so each value below has zero spread across repetitions. Terms count recalled term instances over 5 repetitions of 9 expected terms per locale.

| Engine | Locale | Target WER | Terms recalled | Guard WER | Guard excess insertions | Final word retained |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Apple | pt-BR | 38.46% | 0/45 | 4.26% | 0 | 55/60 |
| Parakeet v3 | pt-BR | 13.46% | 30/45 | 12.77% | 0 | 50/60 |
| Parakeet Ultra | pt-BR | 15.38% | 25/45 | 12.77% | 0 | 45/60 |
| Apple | en-US | 40.91% | 5/45 | 3.85% | 0 | 60/60 |
| Parakeet v3 | en-US | 9.09% | 30/45 | 0% | 0 | 60/60 |
| Parakeet Ultra | en-US | 11.36% | 25/45 | 0% | 0 | 60/60 |

The Portuguese guard gap comes from three of six clips. Per repetition, Apple made 2 word errors in 47 guard words, all on one clip. Parakeet v3 made 6, two on each of three clips: "amanhã de manhã" became "abanhar de banhar", "dormiu" became "do meu", and "quente" and "jantar" became "que" and "jetar". Six guard clips per locale are too few to estimate how often Parakeet damages ordinary Portuguese. They show only that it happens on clean synthetic speech.

A rerun on the same Mac later that day with `--engine apple,parakeet-v3 --vocabulary off --repeats 5` gave 240 passed runs. It reproduced every Apple and Parakeet v3 value in the table, again with zero spread across repetitions. Ultra was not rerun.

Apple's target errors are mostly split or respelled terms, such as "type script", "post 3SQL", and "cubernetes". Parakeet v3 spelled Kubernetes, PostgreSQL in English, Grafana in Portuguese, TypeScript, Docker, and the invented name Zorvex correctly. Both Parakeet models missed Portuguese "PostgreSQL" and "GitHub" and the invented name "Nairumi".

## Release-to-final at real-time pace

Four clips, a target and a guard clip per locale (`pt-01`, `pt-08`, `en-01`, `en-08`), ran with `--realtime` for five repetitions, 20 runs per engine and 60 in total, all passed. Feeding sleeps to the end of each 20 ms buffer. The clock starts at simulated release and stops when the final transcript exists. For Apple that is `finalizeAndFinishThroughEndOfInput()` plus result collection. For Parakeet it is one whole-clip decode. Feeding exceeded the audio duration by a median of 1.4 to 1.7 ms per engine, so every clip was paced in full before release.

| Engine | Runs | Median, ms | Min to max, ms | pt-BR median, ms | en-US median, ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| Apple | 20 | 61.6 | 47.9 to 75.4 | 68.3 | 58.7 |
| Parakeet v3 | 20 | 56.1 | 47.8 to 71.7 | 60.7 | 53.1 |
| Parakeet Ultra | 20 | 65.0 | 44.4 to 75.2 | 67.8 | 63.9 |

The 5.5 ms median gap between Apple and v3 is smaller than either engine's 24 to 28 ms range. This is no measurable difference, not a speedup. Offline, with clips decoded back to back, v3 finalization had a median of 41.4 ms (range 38.4 to 50.2, 120 runs) and Apple 62.8 ms (47.4 to 147.4). Apple's offline number includes processing queued audio, so it is not release latency.

The rerun, at load averages of 8 to 11 against 4 to 5 the first time, gave 40 passed runs. Apple had a median of 71.3 ms (54.5 to 83.7) and v3 65.1 ms (50.1 to 73.3), and the gap is again smaller than either range.

Longer clips ran the same way through a private manifest of the 48 kHz clips from [Decoding at release](#decoding-at-release). The 133-second clip exceeded the default 120-second watchdog on its first try and was rerun with `--timeout-seconds 400`. Parakeet ran one whole-clip decode, as the app does up to 60 seconds, and Apple ran its default accurate mode, which is what an Apple workflow pays today. All 20 runs passed.

| Clip | Audio | Runs per engine | Apple, median ms (range) | Parakeet v3 whole clip, median ms (range) |
| --- | ---: | ---: | ---: | ---: |
| `pt-04` | 3.6 s | 3 | 88 (66 to 91) | 71 (52 to 80) |
| `pt-commas` | 30.5 s | 3 | 171 (159 to 175) | 193 (184 to 200) |
| `pt-44` | 44.0 s | 3 | 147 (147 to 158) | 217 (213 to 225) |
| `pt-132` | 132.7 s | 1 | 142 | 394 |

Apple finalized in about the same time at every length because it recognizes while the audio arrives. Parakeet's whole-clip decode grows with the clip, so it finished 22 ms after Apple at 30 seconds and 70 ms after at 44 seconds. Past 60 seconds the app cuts at pauses, and its paced release on `pt-132` was 207 ms rather than this whole-clip 394 ms. Parakeet's WER on the same runs was 4.2% against Apple's 5.6% on `pt-commas` and 8.1% against 19.2% on `pt-44`. Load averages were 6 to 11.

## What limits these numbers

A Parakeet v3 decode runs the preprocessor, one encoder pass per window, and a token-by-token decode loop. A throwaway timing tool, excluded from the tables, called the loaded models directly. The preprocessor took 1.2 ms on the CPU. The encoder took a median of 25.7 ms on the Neural Engine for a 3.5-second clip and for a 15-second clip alike, because the v3 encoder has one fixed 15-second input shape and FluidAudio pads shorter audio to it. That is about 26 of the 41 ms offline decode. The decode loop's decoder and joint calls take the rest, so the cost grows with the number of tokens. The encoder's fixed window is why a 3-second clip does not decode twice as fast as a 6-second one. A `sample` profile of 288 decodes was inconclusive, because it did not attribute the Swift async frames.

Paced decodes are slower than back-to-back decodes. The same tool measured `pt-01` at a median of 44.6 ms back to back (range 42.2 to 45.8) and 50.2 ms after 3.5 idle seconds (46.9 to 51.9), seven runs each. Idle wake-up explains about 6 ms of the 15 ms difference. The rest was not isolated, and the harness interleaves the Apple runner, whose speech service may still be busy when the next Parakeet request starts.

The host was busy, with load averages of 4.2 to 5.1 during the paced run. Interleaving gives each engine the same noise but cannot remove it.

Model load matters for the app more than decode time. Loading a model from a new path compiled it for the Neural Engine in 13.9 seconds for v3 and 9.5 seconds for Ultra, once per path. Later loads took 93 to 107 ms, and the first decode after loading took 42 to 48 ms. A full 24-clip pass with the v3 runner had a peak memory footprint of 46 MB and a maximum resident set of 90 MB. Ultra measured 49 MB and 93 MB.

## Live preview and final transcript

Apple's `.fastResults` preview with Parakeet's transcript as the final won. The first preview words appeared about 1.06 seconds into speech in every run, and on short clips the final arrived a median of 46 to 61 ms after release, the same range as Apple alone. FluidAudio's sliding-window streaming did worse on preview cadence, accuracy, and CPU, so the app does not use it.

A throwaway prototype, outside the harness, fed 4,096-frame buffers at 48 kHz in real time, the app's capture size, and ran each mode in a fresh process after warming both engines. It recorded the time from simulated release to the final transcript, each preview update, the preview words visible at release, process CPU time for the prototype and for the `localspeechrecognition` service that runs Apple's recognizer, and the peak memory footprint. Neural Engine time does not appear as process CPU, and the prototype's footprint includes its own copy of the converted clip. Short clips are `pt-04` (3.9 s) and `en-01` (3.1 s). Long clips join the twelve clips of a locale with 300 ms of silence between them, 44 seconds in all, and three copies of the Portuguese set make 133 seconds. Modes ran one after another within each repetition, and the first matrix ran five repetitions on short clips, two on 44 seconds, and one on 133 seconds.

| Mode | Clip | Runs | Release to final, median ms (range) | First preview, ms | Preview words at release | Final words | CPU, prototype + speech service, ms | WER |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple, accurate (today's default) | pt-04 | 5 | 90 (78 to 91) | none before release | 0 | 8 | 49 + 124 | 42.9% |
| Apple, fast | pt-04 | 5 | 25 (21 to 30) | 1,061 | 8 | 8 | 40 + 126 | 42.9% |
| Apple fast preview, Parakeet final | pt-04 | 5 | 58 (50 to 62) | 1,063 | 8 | 7 | 89 + 125 | 0% |
| Parakeet only | pt-04 | 5 | 65 (45 to 71) | none | none | 7 | 70 + 0 | 0% |
| Sliding window, 11 s chunks | pt-04 | 5 | 70 (52 to 71) | none before release | 0 | 8 | 147 + 0 | 28.6% |
| Sliding window, 2 s chunks | pt-04 | 5 | 67 (64 to 77) | 3,059 | 7 | 8 | 195 + 0 | 28.6% |
| Apple, accurate | pt-44 | 2 | 157 (147 to 167) | 11,579 | 74 | 96 | 477 + 962 | 19.2% |
| Apple, fast | pt-44 | 2 | 40 (38 to 42) | 1,065 | 94 | 94 | 473 + 1,165 | 25.3% |
| Apple fast preview, Parakeet final | pt-44 | 2 | 181 (174 to 189) | 1,060 | 94 | 97 | 881 + 1,180 | 7.1% |
| Sliding window, 2 s chunks | pt-44 | 2 | 145 (137 to 153) | 3,044 | 105 | 104 | 2,375 + 0 | 16.2% |
| Apple fast preview, Parakeet final | pt-132 | 1 | 369 | 1,067 | 276 | 294 | 1,955 + 2,587 | 7.7% |
| Sliding window, 2 s chunks | pt-132 | 1 | 141 | 3,057 | 323 | 325 | 7,449 + 0 | 18.2% |

`en-01` matched `pt-04`. Apple accurate showed nothing before release and finalized in a median of 63 ms, the fast-preview hybrid finalized in 61 ms with its first preview at 1,071 ms, and every Parakeet mode scored 0% WER against Apple's 14.3%.

Apple's default accurate mode held volatile results back. On a 4-second clip it showed no preview words before release, and on the 44-second clip its first words came at 11.6 seconds, in bursts up to 11.4 seconds apart. With `.fastResults` the first words came at about 1.06 seconds in every run, updates arrived in bursts with a median gap of 2 to 3 ms, and the longest gap was 0.94 seconds on short clips and 1.96 seconds on 44 seconds. Fast mode cost Apple accuracy on the 44-second clip, 25.3% against 19.2%. In a Parakeet run Apple's text is only the preview and the backup, so the hybrid always uses fast results, and this hides none of Parakeet's accuracy.

FluidAudio 0.18.0's `SlidingWindowAsrManager` processes whole chunks plus right context and never reads its `hypothesisChunkSeconds` setting, so with the default 11-second chunk the first update came 13 seconds in. With 2-second chunks and 10 seconds of left context, updates came every 2 seconds starting at 3 seconds. Its WER more than doubled on long audio, 16.2% and 18.2% against 7.1% and 7.7%, and prototype CPU was 2.7 to 3.8 times the hybrid's. On the short clip both window sizes split "TypeScript" in their final flush.

Cancelling Apple at release before decoding, finalized slower, a median of 82 to 97 ms, because the prototype awaited the analyzer's cancellation first. The app lets both finish concurrently and cancels Apple after Parakeet returns. Running Apple alongside did not slow Parakeet's decode, 369 ms with Apple and 375 ms alone on 133 seconds.

## Segmented decoding

A whole-clip decode at release grows with the recording, about 2.8 ms per second of audio here, because FluidAudio runs one 15-second encoder window for roughly every 11 seconds of audio. The first app design therefore decoded while recording. Each time 15 seconds accumulated, `ParakeetTranscriber` cut at the center of the quietest 200 ms between 10 and 15 seconds, decoded that segment, and kept the remainder, so release waited for at most one segment. [Decoding at release](#decoding-at-release) explains why the app replaced it.

A second matrix ran the segmented hybrid against the whole-clip hybrid, three repetitions on short clips, two on each 44-second clip, and one on 133 seconds, with an Apple fast baseline on 133 seconds. That matrix cut at the first quiet 20 ms frame.

| Clip | Whole-clip release to final, ms | Segmented release to final, ms | Apple fast, ms |
| --- | ---: | ---: | ---: |
| pt-04 | 49 (44 to 50) | 46 (44 to 52) | 25 (21 to 30), first matrix |
| en-01 | 51 (48 to 54) | 52 (52 to 54) | 45 (38 to 51), first matrix |
| pt-44 | 181 (181 to 182) | 71 (70 to 73) | 40 (38 to 42), first matrix |
| en-44 | 189 (189 to 189) | 72 (71 to 74) | not run |
| pt-132 | 369, first matrix | 62 | 51 |

Cutting at the first quiet frame left a segment almost no trailing silence, and the decoder dropped final words. "depois da reunião" lost "da reunião" at one boundary. Decoding the same converted audio offline, which reproduces paced output, compared three cuts.

| Clip | Whole clip | First quiet 20 ms | Center of quietest 200 ms |
| --- | ---: | ---: | ---: |
| pt-44 | 8/99, 8.1% | 10/99, 10.1% | 7/99, 7.1% |
| en-44 | 2/96, 2.1% | 2/96, 2.1% | 2/96, 2.1% |
| pt-132 | 24/297, 8.1% | 39/297, 13.1% | 21/297, 7.1% |

On these clips the centered cut matched or beat the whole-clip decode, but each clip had a 300 ms pause at every sentence boundary, so every cut fell between two sentences. On continuous speech the same cut ended a sentence at every cut, so the app no longer cuts dictations of up to 60 seconds. See [Decoding at release](#decoding-at-release). Offline whole-clip WER on `pt-44` differs from the paced 7.1% by one word because the offline path resamples 24 kHz audio directly instead of through 48 kHz.

## Decoding at release

The centered cut put a false sentence break at every cut in continuous speech, because every Parakeet decode ends its text as a finished sentence. The review's four clips are continuous macOS-voice dictations of 26.6 to 32.7 seconds with no sentence boundary inside, two of them with pauses at commas. With 15-second segments all 7 cuts ended a sentence mid-clause, as in "...até que o ambiente. De testes ficasse estável...". The whole-clip decode of the same audio inserted none.

The app now decodes a dictation of up to 60 seconds once at release, through FluidAudio's own long-audio chunking, which overlaps its windows and merges tokens across them. Past 60 seconds it cuts at the center of the quietest 300 ms of the last 15 seconds, and only when no frame there reaches the speech level of the rule in [Noise and quiet speech](#noise-and-quiet-speech). Once 75 seconds have accumulated it cuts at the quietest 300 ms anyway, so no decode exceeds 75 seconds of audio.

A throwaway probe ran the app's `ParakeetTranscriber` and a verbatim copy of the earlier segmented one against the loaded model in a build with Release-level Swift optimization. It counted the cuts that fell outside a sentence or clip boundary of the joined clips and still ended their segment with sentence punctuation.

| Clip | Length | Cuts before | Inserted breaks before | Cuts after | Inserted breaks after |
| --- | ---: | ---: | ---: | ---: | ---: |
| `en-continuous` | 26.6 s | 1 | 1 | 0 | 0 |
| `pt-continuous` | 32.7 s | 2 | 2 | 0 | 0 |
| `en-commas` | 27.1 s | 2 | 2 | 0 | 0 |
| `pt-commas` | 30.5 s | 2 | 2 | 0 | 0 |
| `pt-44` | 44.0 s | 3 | 0 | 0 | 0 |
| `en-44` | 40.8 s | 3 | 0 | 0 | 0 |
| `pt-132` | 132.7 s | 11 | 0 | 2 | 0 |
| `pt-continuous-126` | 126.8 s | 9 | 6 | 1 | 0 |

`pt-44`, `en-44`, and `pt-132` join the evaluation sentences with 300 ms of silence, so every earlier cut fell between sentences. `pt-continuous-126` joins the review's Portuguese continuous and comma clips twice with 120 ms gaps. After the change its one cut fell at a join between clips, and both cuts on `pt-132` fell between sentences. A cut past 60 seconds can still land in a pause inside a sentence, and real speech with such pauses is unmeasured.

Word accuracy moved in both directions. On continuous speech the single decode was better, 12 errors against 14 on the four review clips and 17 against 20 on `pt-continuous-126`. On pause-separated speech the 15-second segments were better, 7 against 8 errors on `pt-44` and 22 against 28 on `pt-132`, with `en-44` tied at 2. FluidAudio's own windows overlap and merge mid-sentence, while the old cuts on these clips always fell in a pause. The earlier table in [Segmented decoding](#segmented-decoding) showed the same gap.

Release now waits for a whole-clip decode, which grows with the recording. The probe decoded growing prefixes of `pt-132` after 2 idle seconds each, five runs per length in alternating order.

| Audio | Decode, median ms | Range, ms |
| ---: | ---: | ---: |
| 4 s | 81 | 69 to 87 |
| 15 s | 128 | 119 to 135 |
| 30 s | 180 | 178 to 185 |
| 44 s | 200 | 194 to 208 |
| 60 s | 226 | 219 to 257 |
| 75 s | 274 | 271 to 279 |
| 90 s | 309 | 303 to 339 |
| 133 s | 378 | 376 to 406 |

The 75-second row came from a later run in which 60 seconds measured 246 ms, so runs differed by about 20 ms on this busy machine. Up to 15 seconds the encoder runs one fixed 15-second window and the cost grows with the words decoded. Past 15 seconds FluidAudio adds a window for about every 11 seconds of audio, about 2.2 ms per second here.

The probe then paced each clip in 4,096-frame buffers at 48 kHz, decoding during recording as the app does, and timed from the end of the last buffer to the final transcript. Both designs ran in one process, one after the other for each clip, in alternating order, five repetitions on the shorter clips and three on `pt-132`. Apple's preview recognizer was not running, so these numbers leave out its share of the machine.

| Clip | Audio | 15-second segments, median ms (range) | One decode up to 60 s, median ms (range) |
| --- | ---: | ---: | ---: |
| `pt-04` | 3.6 s | 92 (83 to 116) | 93 (87 to 112) |
| `pt-commas` | 30.5 s | 97 (85 to 101) | 216 (205 to 226) |
| `pt-44` | 44.0 s | 106 (98 to 115) | 231 (226 to 237) |
| `pt-132` | 132.7 s | 119 (94 to 127) | 207 (207 to 242) |

Up to 15 seconds the two designs do the same work, and the gap is smaller than the spread. Past it, release costs 88 to 125 ms more, because the final decode covers everything since the last cut, up to 75 seconds, instead of at most 15. In every run the final decode was all but 0.4 to 7 ms of release-to-final. The speech check took a median of 0.11 ms for 4 seconds of audio and 2.0 ms for 75 seconds. On `pt-132` the last cut left 32.4 seconds for release. [Release-to-final at real-time pace](#release-to-final-at-real-time-pace) compares Apple's default recognizer at the same lengths.

Load averages were 7 to 22 during these runs. An unrelated test process used about 8 cores for part of them, and nothing was stopped. Running both designs in one process, interleaved, gave them the same noise.

## Memory for a one-hour dictation

A 59.9-minute file, the 133-second set repeated 27 times, streamed through each design offline in 4,096-frame chunks after the model loaded. Whole-clip decoding held every sample and peaked at a 683 MB footprint, 643 MB above the loaded-model baseline, and its final decode took 7.4 seconds. Segmented decoding peaked at 52 MB, 12 MB above baseline. Its final decode took 64 ms, and its segment decodes summed to 21.7 seconds over the hour, about 0.6% of real time. WER over the hour was 6.4% segmented and 8.3% whole-clip. The 15-second design held at most 15 seconds of 16 kHz mono audio, 0.96 MB, plus a copy of the segment being decoded.

The probe in [Decoding at release](#decoding-at-release) streamed the same hour through the app's current `ParakeetTranscriber` and through the 15-second design, each in a fresh process. The current design peaked 71 MB above its loaded-model baseline against 13 MB. It cut 72 times and never decoded more than 52 seconds at once, and its decodes summed to 14.3 seconds against 22.8 seconds, because each of the 324 short segments paid for a full 15-second encoder window. A single decode peaked about 7 MB above the baseline up to 15 seconds and 21 to 34 MB from 30 to 75 seconds, FluidAudio's parallel long-audio path. The pending buffer now holds at most 75 seconds of 16 kHz audio, 4.8 MB, plus a copy of the segment being decoded. About 27 MB of the hour's peak is not attributed. Every decode stays at or under 75 seconds, so the peak does not grow with the recording. WER over the hour was 8.7% against 6.6%, the same direction as the whole-clip and segmented decodes above.

## Noise and quiet speech

Parakeet returned text for presses that held no speech, and Apple did not. The review's 20 synthetic noise presses, white noise of 0.4 to 1 second at RMS 0.001 to 0.01, gave "Yeah." on 8 through `AppState`, and Apple's runner returned nothing for all 20. The same hallucination appended " Yeah." to a 15.1-second dictation when a 15-second cut left 0.2 seconds of trailing room noise, padded to 0.5 seconds.

A decode now runs only when its audio holds speech by one rule. After a one-pole high-pass near 76 Hz, at least 100 ms of its 20 ms frames must sit 6 dB or more above its own 10th-percentile frame energy and above -66 dBFS. The rule needs no Apple result and no model, so it holds when Apple's assets are missing, and it also covers room noise left after the last cut of a long dictation. When it does reject real speech, the run falls back to Apple's transcript.

The rule was chosen on a synthetic set in Python and then checked through the app's `ParakeetTranscriber` with the real model.

- 50 noise clips. They are the review's 20, pink, brown, and 60 Hz high-passed brown noise of 0.5, 1, and 3 seconds at -60, -50, and -40 dBFS, 3 seconds of white noise at -50 and -40 dBFS, and 1 second of room noise with three keyboard-like clicks. Without the rule 11 produced text, "Yeah." on 10 and "Thank you." on one brown-noise clip. With it none did.
- 38 speech clips. They are "Sim.", "Não.", and "Ok, pode mandar." in a Portuguese voice, "Yes." and "No." in an English voice, and "Yes." and "Please send me the report tomorrow morning." in the English Whisper voice. Each sat in a press with 300 ms of room noise on both sides, at an active level of -25, -35, and -45 dBFS over pink room noise at -55 dBFS. Five of them were repeated at 0, 5, and 10 dB above pink room noise at -50 dBFS, and one with 3 seconds of room noise before or after. The rule rejected none of the 38, and every transcript matched the one without the rule.

Through `AppState` with the real model, all 20 review presses now end as "Nothing heard" with no clipboard write or history entry, and the 15.1-second dictation ends without " Yeah.". The rule leaves Parakeet's own misses alone. Parakeet heard "Não." as "No." at every level, and "Sim." and "Não." at -45 dBFS as "Mm." and "Mm-hmm.".

Stricter variants rejected speech that Parakeet transcribed correctly. At 8 or 10 dB the rule rejected "Yes." at 0 dB SNR, and without the high-pass the sub-audio drift in one brown-noise clip passed it and produced "Thank you.". Of the other candidates, treating Apple's empty fast result as no speech would make every delivery wait for Apple, fails when Apple's assets are missing, and leaves the remainder after a cut unhandled. FluidAudio's VAD loads a separate Silero Core ML model from Hugging Face. Skipping a short quiet final segment is one case of this rule.

All noise here is synthetic and all speech is a macOS voice, so real rooms, microphones, and whispers remain untested. Speech-like noise such as a television, and transients that add up to more than about 100 ms, such as typing, can pass the rule, and Parakeet then decides.

## Launch time and download size

FluidAudio makes the app about 4.4 times as large to download and adds about 0.17 seconds to the first launch of a new build. Later launches showed no measurable difference.

`main` at `965e9fe` and this branch were each archived as an inert host, universal and Release, with ad-hoc signing and the same package versions. The production `SyrupApp` stays linked through a call behind a launch argument that is never passed, so the linker keeps the same code, and a new entry point exits from `applicationDidFinishLaunching`. Both used the bundle ID `org.syrup.SyrupIsolatedTests` that `script/test-isolated.sh` uses. Nothing launched the production app or touched its Application Support data.

| Build | Executable, universal | arm64 slice | ZIP |
| --- | ---: | ---: | ---: |
| `main` | 7.1 MB | 3.4 MB | 5.8 MB |
| This branch | 39.4 MB | 19.2 MB | 25.5 MB |

Release 0.7 shipped as a 5.7 MB ZIP, so `main` archived this way comes within 0.1 MB of it. The ZIPs are `ditto -c -k --keepParent` archives of the archived apps, 5,799,444 bytes for `main` and 25,520,098 bytes for the branch.

| Launch | Runs per build | `main`, median ms (range) | This branch, median ms (range) |
| --- | ---: | ---: | ---: |
| First launch of a newly signed copy | 6 | 398 (393 to 403) | 564 (555 to 619) |
| Second launch of that copy | 6 | 182 (133 to 186) | 130 (126 to 180) |
| Repeated launches of the archived app | 29 | 181 (128 to 188) | 180 (127 to 186) |

Each run timed the process from spawn to exit, and the two builds alternated. Each first-launch copy was re-signed with its own identifier, so macOS saw a new code directory hash. That launch took 166 ms longer for the branch, and the ranges do not overlap. On later launches the gap is smaller than the spread. Signature checks and dynamic-linker setup for a new binary grow with its size, which likely explains the first-launch gap, but it was not profiled. Gatekeeper's check of a downloaded app, a cold start after reboot, and the full app's own start-up work were not measured. The inert host was ready in 0.56 seconds on its first launch, under the 1-second cold-start target, which leaves about 0.44 seconds for the rest of the app's start-up. Load averages were 14 to 16.

## x86_64

The production target builds universal. `xcodebuild -scheme Syrup -configuration Release -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build` succeeded in 1 minute 53 seconds from a copy of the tree, and `lipo -archs` reports `x86_64 arm64` for the 77 MB executable, which is 39 MB once archived and stripped. FluidAudio's prebuilt `NemoTextProcessing` xcframework carries both macOS slices. FluidAudio's own `isModelValid` refuses Intel Macs, and `ParakeetEngine.isSupported` is false there, so an Intel Mac never offers Parakeet and every run uses Apple. The Intel path was not run on Intel hardware.

## Glossary vocabulary boosting

FluidAudio's CTC vocabulary boosting raised term recall but replaced an ordinary word on an English guard clip in every run, so the app does not use it. The prompt-side glossary is unchanged, and no CTC model is downloaded.

The harness runner loads `parakeet-ctc-110m`, 98 MB on disk, from its own cache. It tokenizes the nine target terms with that model's tokenizer, spots them with `CtcKeywordSpotter`, and applies `VocabularyRescorer.ctcTokenRescore` to Parakeet's transcript and token timings. These are the steps of `VocabularyBoostingSession.rescore`, without that type's fixed use of FluidAudio's default model directory. Aliases come from `script/recognition-eval/apple-mishearings.json`, Apple's own misrecognitions of each term in these clips that contain letters, which is the evidence glossary learning would propose. Each matrix ran all 24 clips with boosting off and on in alternating order for five repetitions, 240 runs, all passed. Every clip produced the same hypothesis in all five repetitions, so run-to-run spread is zero.

| Rescorer | Glossary input | Locale | Target WER | Terms recalled | Guard WER | Guard insertions |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| No boosting | none | en-US | 9.09% | 30/45 | 0% | 0 |
| No boosting | none | pt-BR | 13.46% | 30/45 | 12.77% | 0 |
| FluidAudio default | terms | en-US | 36.36% | 30/45 | 51.92% | 45 |
| FluidAudio default | terms | pt-BR | 53.85% | 25/45 | 55.32% | 55 |
| FluidAudio default | terms and aliases | en-US | 36.36% | 35/45 | 51.92% | 45 |
| FluidAudio default | terms and aliases | pt-BR | 51.92% | 30/45 | 57.45% | 55 |
| Rescue floors | terms and aliases | en-US | 6.82% | 45/45 | 1.92% | 5 |
| Rescue floors | terms and aliases | pt-BR | 7.69% | 40/45 | 19.15% | 10 |
| Rescue off | terms | en-US | 4.55% | 40/45 | 1.92% | 5 |
| Rescue off | terms | pt-BR | 5.77% | 40/45 | 12.77% | 0 |
| Rescue off | terms and aliases | en-US | 4.55% | 45/45 | 1.92% | 5 |
| Rescue off | terms and aliases | pt-BR | 7.69% | 40/45 | 12.77% | 0 |

Guard insertions count vocabulary terms beyond those in the reference, over 30 guard runs. With FluidAudio's default configuration, the spotter-anchored rescue pass rewrote ordinary words. "Check the profana dashboard after lunch." became "Check the Grafana Grafana", and guard WER passed 50% in both locales. `VocabularyBoostingSession.itnDefaultConfig`, FluidAudio's recommended rescue similarity floors, still added ten insertions to Portuguese guards.

With rescue off, boosting fixed "poste de SQL" to "PostgreSQL", "profana" to "Grafana", and "Mirella" to "Mirela", and it halved target WER. It also turned "She left a blue umbrella beside the front door." into "She left a blue Mirela beside the front door." in all five repetitions. Guard WER rose from 0% to 1.92% and insertions from 0 to 5, beyond the zero spread, so boosting fails the requirement that guard WER and insertions not regress. With aliases the rescorer also deleted neighboring words on two target clips, "short" in "a short TypeScript example" and "sobre" in "um tutorial sobre TypeScript", because it rebuilds text from word timings.

Latency at real-time pace used rescue off with terms only on `pt-01`, `pt-08`, `en-01`, and `en-08`, five repetitions with boosting off and on, 40 runs, all passed. On target clips finalization rose from a median of 45.0 ms (43.0 to 72.7) to 163.9 ms (154.8 to 199.5), and the rescore stage alone had a median of 117.6 ms (110.9 to 144.7). That is under the 150 ms limit, but it nearly quadruples release-to-final for a short clip. The rescore stage covers the CTC encoder pass, keyword spotting, and rescoring, and was not decomposed further.

These results cannot establish a real false-replacement rate. Six guard clips per locale are too few, the CTC model's tokenizer is English with 1,024 tokens, and the terms are nine invented or technical words. A real glossary of up to 100 terms changes FluidAudio's vocabulary-size thresholds.

## What synthetic voices cannot establish

These are three macOS voices reading invented, clearly articulated sentences, with clean digital audio and exact clip boundaries. They lack the user's accent, hesitation, code-switching, room noise, microphone, and capture timing. Recognition differences of this size on real speech, the guard-clip damage rate, and term recall for the user's own vocabulary all remain unverified. So does accuracy for any language other than pt-BR and en-US. Either engine's errors on real voices may differ from its errors here, so neither ranking transfers without consented real-voice clips through `SYRUP_EVAL_PRIVATE_MANIFEST`.

## Reproduce and inspect

```sh
script/recognition-eval.sh run --engine apple,parakeet-v3,parakeet-ultra --vocabulary off --repeats 5 --output .cache/recognition-eval/engines-new.jsonl
script/recognition-eval.sh run --engine apple,parakeet-v3,parakeet-ultra --vocabulary off --realtime --clips pt-01,pt-08,en-01,en-08 --repeats 5 --output .cache/recognition-eval/engines-realtime-new.jsonl
script/recognition-eval.sh run --engine parakeet-v3 --vocabulary both --aliases script/recognition-eval/apple-mishearings.json --boost-rescue off --repeats 5 --output .cache/recognition-eval/boost-new.jsonl
python3 -B -m unittest discover -s script/recognition-eval -p 'test_*.py'
```

The preview numbers and the first segmentation and memory numbers come from a throwaway Swift prototype that is not in the repository. The noise, sentence-break, decode-cost, release-to-final, and one-hour numbers in the later sections come from a second throwaway probe test, also not in the repository, which ran the app's `ParakeetTranscriber` and a verbatim copy of the 15-second design against the loaded model. `ParakeetTranscriberTests` checks the app's one-pass limit, its pause cut, and its speech check. The [tool usage](../../script/recognition-eval/usage.md) defines the engines, timing boundaries, and model cache. The raw results are `engines-offline.jsonl` and `engines-realtime.jsonl` with their summaries and load-average snapshots under `.cache/recognition-eval/` in the measuring worktree, which Git ignores. Ten harness tests passed, including engine validation before any build, alias validation, and the separate target and guard WER fields. Raw boosting results are the `boost-*.jsonl` files beside them.
