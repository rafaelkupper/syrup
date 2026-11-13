# Early transformation on a quiet hold

Personal identifiers and machine paths in this record use illustrative placeholders.

Implemented against base `c162d8e`, default off, in `/path/to/syrup/feature-worktree`. No commit, branch, push, production launch, real hotkey, microphone capture, or app-model download was performed. The settings UI is outside this verification scope. The protected product, architecture, README, and QA documents were not changed.

## Behavior

`transformsOnPause` is a raw UserDefaults Bool defaulting to false. Each run freezes the preference, provider snapshot, and the speech-engine selection used by that run. Only Apple-only voice dictation with Apple On-Device or an OpenAI-compatible endpoint resolving to a loopback host qualifies. Codex, remote endpoints, revisions, selected-text input, transcribe-only runs, and runs using a downloadable transcriber do not qualify. A voice workflow's optional selection context is included in the same composed instruction used at release.

While capturing, both audio below -45 dBFS and unchanged live transcript must last 300 ms. Partial callbacks reach the scheduler even with no cue or a hidden transcript. The same trimming and corrections produce speculative and final input. Equality compares UTF-8 bytes, including differences that Swift String's canonical equality would hide. An identical corrected input never restarts; a different stable input cancels and replaces the previous attempt.

Each attempt obtains a fresh transformer from the frozen provider snapshot and calls the provider's atomic transform, including its existing output normalization. Apple's prepared session is never used by the attempt. Attempts have no delivery or history side effects. A matching successful attempt uses the shared atomic clipboard, history, and auto-paste commit path even when streaming is enabled. Mismatch, cancellation, or failure falls back to the existing path; run cancellation prevents delivery.

`PipelineMetricsRecording` now records `quiet_before_release_ms`, including when the preference is off. Eligible runs record `pause_transformation=hit|miss|none|failed` and `attempt_count` on cleanup, without content or content lengths. For a hit, `translation` records the full attempt's transform duration retrospectively, using the injected monotonic clock; it excludes transformer construction just like the ordinary atomic span. This duration appears in the stage log, without a retrospective signpost interval. `release_to_clipboard` still measures the actual stop-request-to-clipboard interval. Cancelled runs with an attempt are counted as misses.

## Verification

Host: Mac16,7, arm64, 14 logical CPUs, macOS 27.0.1 (26A434), Xcode SDK macOS 27.2, application deployment target macOS 26. Tests used the disposable inert host built by `script/test-isolated.sh`; production compilation used a separate derived-data directory. No real clipboard or input events were used by the new tests.

Commands executed from this worktree:

```sh
xcodegen
SYRUP_TEST_ROOT=$(mktemp -d /tmp/syrup-early.XXXXXX) script/test-isolated.sh \
  -only-testing:SyrupTests/PauseTransformationTests \
  -only-testing:SyrupTests/PauseTransformationPolicyTests \
  -only-testing:SyrupTests/AppStateTests \
  -only-testing:SyrupTests/ReleaseTailPipelineTests \
  -only-testing:SyrupTests/ParakeetPipelineTests
# The same owned temporary root was reused for the whole suite:
SYRUP_TEST_ROOT=<owned-temporary-root> script/test-isolated.sh
xcodebuild -scheme Syrup -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath <unique-/tmp/syrup-early-build-directory>
python3 -B -m unittest discover -s script/recognition-eval -p 'test_*.py'
git diff --check
```

Results from xcresult summaries, not just the console's inclusive totals:

| Check | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Initial focused suites, including AppState | 118 | 0 | 0 |
| Expanded five focused suites | 155 | 0 | 0 |
| Whole isolated suite, 77 suites, 625 total tests | 622 | 0 | 3 |
| Recognition evaluation Python tests | 12 | 0 | 0 |
| Production target Debug compilation, signing disabled | Passed | 0 | 0 |

The three skipped tests are `ReleasePathTimingTests.levelTapAndMainActorHops`, `ReleasePathTimingTests.quietReleaseCostAgainstAMenuStop` (opt-in timing tests), and `AppleOnDeviceTransformerTests.availableModelSmokeTransformsShortPhrase` (real-model smoke test). No flaky test, test timeout, or test-host launch failure occurred. The first focused build found a missing test argument before any tests ran; it was corrected and rerun. Xcode printed a CoreSimulator version warning; macOS builds and test execution succeeded.

Focused coverage includes a pending speculative hit with one transform call total, no prepared-transformer use, one clipboard write, one success history entry and atomic auto-paste with streaming enabled; mismatch cancellation and normal fallback; identical-input deduplication and replacement; Esc and transcriber failure cancellation; swallowed speculative errors without failed history; Codex and remote-host exclusion; resolved-environment endpoint checks; setting snapshot/default/persistence; corrections, UTF-8 identity, quiet/stability thresholds, release-tail exclusion, non-dictation/non-voice/non-Apple eligibility, and metrics with the setting off.

## Recognition readiness measurement

The claim tested was whether Apple's live transcript becomes byte-identical to its final transcript within 0.3, 0.6, or 1.0 seconds after the end of speech. This measures a prerequisite for reuse, not transformation speed or a production hit rate.

The optimized Swift runner feeds real installed Apple SpeechTranscriber assets in paced 20 ms buffers. The added `--prefer-fast-results` switch compares accurate and fast modes. It timestamps each finalized-plus-volatile callback, then finds the first trimmed UTF-8 match with the eventual final transcript strictly before simulated release. Non-matches are retained as missing observations, not dropped or converted to zero. Finalization-induced callbacks do not count as live readiness.

The normal `generate` command stalled in `say` on its first file. That task-owned process was interrupted. Instead, four existing synthetic clips were copied from `/path/to/syrup/.cache/recognition-eval/audio/` only after verifying the committed manifests were byte-identical and all four audio SHA-256 hashes matched that cache's `fixtures.json`. The clips are `pt-01`, `pt-08`, `en-01`, and `en-08`, using Luciana, Samantha, and Eddy voices. Each local copy received 1.2 seconds of zero-valued trailing audio. Their measured total end silence was 1.406-1.607 seconds. The source clips were not modified. Metadata is retained in `.cache/recognition-eval/reused-fixtures.json`.

Five paired rounds were run. Each round ran all four clips once in each mode, reversing mode order on odd rounds. Vocabulary was off. This gives 10 trials per locale per mode and 40 total. All 40 completed successfully with nonempty final transcripts, zero errors, and zero timeouts. Feed duration exceeded audio duration by only 0.184-2.666 ms, confirming paced feeding. Median finalization was 27.367 ms, range 11.146-140.356 ms. Final transcripts were scored by the existing harness; byte matching is against the final recognition, not against an assumption of perfect recognition accuracy.

```sh
# For round 0 through 4, reverse the order of these two commands on odd rounds:
script/recognition-eval.sh run --realtime --clips pt-01,pt-08,en-01,en-08 \
  --vocabulary off --repeats 1 --output .cache/recognition-eval/early-accurate-<round>.jsonl
script/recognition-eval.sh run --realtime --clips pt-01,pt-08,en-01,en-08 \
  --vocabulary off --repeats 1 --prefer-fast-results \
  --output .cache/recognition-eval/early-fast-<round>.jsonl
script/recognition-eval.sh summary .cache/recognition-eval/early-combined.jsonl
```

| Mode | Locale | Trials | Match before release | First match after speech, median (range), ms | Within 300 ms | Within 600 ms | Within 1000 ms |
| --- | --- | ---: | ---: | --- | ---: | ---: | ---: |
| Accurate | pt-BR | 10 | 0 | Not observed in 1406-1607 ms of silence | 0/10 | 0/10 | 0/10 |
| Accurate | en-US | 10 | 0 | Not observed in 1413-1604 ms of silence | 0/10 | 0/10 | 0/10 |
| Fast | pt-BR | 10 | 5 | 1387.420 (1386.236-1389.757) | 0/10 | 0/10 | 0/10 |
| Fast | en-US | 10 | 8 | 1210.151 (1208.074-1415.256) | 0/10 | 0/10 | 0/10 |

Medians for fast mode include only observed matches; the remaining trials are explicitly censored at release. Only five fast en-US trials had at least 300 ms left after their first matching partial; no other group did. This is an upper bound on scheduler opportunity, not proof the transcript stayed unchanged or that a transform could complete in that interval.

The host was not idle. Initial load averages were 9.80/6.78/5.33 on 14 CPUs, on a busy host. Modes were interleaved to limit drift. No end-to-end speedup, microphone hit rate, or accurate-mode readiness beyond the 1.4-1.6 second observation window is claimed. The provider request remains the intended latency target, but no real provider transform was benchmarked here.

Raw synthetic results and their numeric summary are retained under ignored `.cache/recognition-eval/early-*.jsonl` and `early-summary.json`. Build/test logs are retained in ignored `.cache/recognition-eval/early-build-logs/`. Task-created temporary build/test directories were removed after collecting the results.

## Proposed documentation text

### ARCHITECTURE.md

Early transformation is a default-off optimization for Apple-only voice dictation with Apple On-Device or a loopback OpenAI-compatible endpoint. After 300 ms of quiet audio and unchanged partial transcript, a run may transform its corrected partial input with a fresh transformer from its provider snapshot. Release reuses the result only when corrected final input has identical UTF-8 bytes. A hit uses atomic delivery even when streaming is enabled. Mismatch or failure follows the existing delivery path. Cancellation discards speculative work. Metrics record quiet-before-release duration and eligible-run outcome and attempt count without user content. Reused translation duration covers the actual speculative call; release-to-clipboard still begins at the stop request.

### PRODUCT.md

Transform on pause can begin processing during a quiet hold to reduce the wait after release. It is off by default and applies only to voice dictation using Apple speech recognition and a local transformation provider. Results appear only after release and only after matching the final corrected transcript. Unsupported runs keep their existing behavior. Recognition may update too late for this optimization to help short pauses.

### docs/QA.md

With Transform on pause enabled and a local provider, hold through a quiet pause, then release. Verify one final clipboard write, normal history and auto-paste, and atomic delivery on a hit even with streaming enabled. Speak again before release and confirm stale work is cancelled when a different stable input replaces it, or at final-input mismatch. Cancel during capture and while awaiting the attempt after release; neither may write the clipboard. Repeat with hidden transcript and hidden cue. Confirm revisions, selected-text input, transcribe-only runs, downloadable speech engines, Codex, and remote endpoints do not speculate. Verify quiet-before-release metrics with the toggle off, and compare eligible outcome and attempt count with it on. Measure real microphone hit rates separately from synthetic readiness.

## Remaining acceptance and risks

Real microphone hit rates, representative long dictations, real Apple model contention, real local-server performance, and actual release-to-clipboard improvement are unverified. The feature creates extra local inference work on misses, and fresh Apple sessions may contend for model resources. Default accurate recognition yielded no usable early matches on these short clips. The new setting has no UI in this worktree by request. The measured host runs macOS 27, so macOS 26 runtime behavior remains untested. All new delivery/cancellation assertions used injected fakes and an inert test host.

## 2026-11-05 offline prefix follow-up

This follow-up runs in the main checkout, `/path/to/syrup`, with the existing three-feature work preserved. The gate is accurate-mode trimmed UTF-8 equality of at least 70% at speech end plus 300 ms or plus 600 ms. Prefix recognition uses a separate analyzer, unpaced input, and explicit finalization; the reference uses paced input and finalization at simulated release. Both use the same locale, recognition mode, vocabulary setting, and source clip.

The source cache contains all 24 synthetic fixtures. Their SHA-256 values were verified against `.cache/recognition-eval/fixtures.json`. This run selects eight per locale: IDs 01, 02, 03, 05, 07, 08, 10, and 12, split equally between vocabulary targets and guard sentences. The runner pads the reference to 1500 ms of end silence in memory and trims or pads prefixes to the detected speech endpoint plus 300 or 600 ms. No source WAV is modified and no new audio file is written. The endpoint is the last sample above absolute amplitude 0.01, as in the earlier measurement; it is a synthetic endpoint estimate, not microphone voice activity detection.

Three rounds run each clip once per recognition mode and endpoint, with vocabulary off. Mode order reverses on the middle round, as does reference/prefix order. Clip order uses the harness's seeded shuffle. Each result records its round as `repetition`, allowing exact pairing rather than comparison with a pooled transcript. The full matrix has 288 recognition requests and 192 prefix/reference comparisons. Failures and empty transcripts remain in the equality denominator. Equality trims surrounding whitespace but does not normalize Unicode, case, punctuation, or words.

Host: arm64, 14 logical CPUs, macOS 27.0.1 (26A434), Xcode 27.2 (27B52). Initial load averages were 7.87/9.55/8.53. The host was not idle. Builds and tests were kept out of the recognition measurement window. Offline latency is full request wall time, including file reading, prefix construction, locale lookup, conversion, analyzer preparation, feed, finalization, and result collection. These measurements do not include a transformer, clipboard delivery, real microphone capture, or concurrent live/offline analyzers.

Raw synthetic results are retained under ignored `.cache/recognition-eval/offline-2026-11-05/`. The new `--prefix-after-speech-ms` and `--end-silence-ms` switches construct these inputs without disk audio copies. `compare-pauses` pairs results and reports equality, invalid counts, and latency by clip length. The harness unit tests cover option forwarding, invalid combinations, failed/empty results, exact Unicode bytes, pairing, and duplicate/missing references.

Commands, with a new output path for each round/mode/endpoint:

```sh
# CLIPS=pt-01,pt-02,pt-03,pt-05,pt-07,pt-08,pt-10,pt-12,en-01,en-02,en-03,en-05,en-07,en-08,en-10,en-12
script/recognition-eval.sh run --clips "$CLIPS" --vocabulary off --repeats 1 \
  --end-silence-ms 1500 --realtime --output <round-mode-release.jsonl>
script/recognition-eval.sh run --clips "$CLIPS" --vocabulary off --repeats 1 \
  --end-silence-ms 1500 --prefix-after-speech-ms 300 --output <round-mode-prefix300.jsonl>
script/recognition-eval.sh run --clips "$CLIPS" --vocabulary off --repeats 1 \
  --end-silence-ms 1500 --prefix-after-speech-ms 600 --output <round-mode-prefix600.jsonl>
# Add --prefer-fast-results for fast mode; repeat each combination for three rounds.
# Before combining, assign each row its round number in the repetition field.
script/recognition-eval.sh compare-pauses .cache/recognition-eval/offline-2026-11-05/combined.jsonl
python3 -B -m unittest discover -s script/recognition-eval -p 'test_*.py'
```

### Gate result

The gate passes at both offsets. All 288 requests completed with nonempty transcripts, zero failures, and zero timeouts. Each table cell compares 8 distinct clips over 3 repetitions.

| Mode | Locale | +300 ms equality | +600 ms equality |
| --- | --- | ---: | ---: |
| Accurate | pt-BR | 21/24 (87.5%) | 24/24 (100.0%) |
| Accurate | en-US | 21/24 (87.5%) | 24/24 (100.0%) |
| Fast | pt-BR | 24/24 (100.0%) | 21/24 (87.5%) |
| Fast | en-US | 21/24 (87.5%) | 21/24 (87.5%) |

Actual prefix endpoints differed from the requested cut by at most 0.042 ms, less than one 16 kHz output frame. Realtime feed overruns ranged from 0.078 to 4.069 ms. Each offline request finalized its own analyzer; outputs were neither replayed nor cached. Vocabulary-on trials were skipped because another complete paced matrix would double measurement time. The gate and implementation use frozen per-run vocabulary, but this experiment establishes equality only with vocabulary off.

### Offline latency by clip length

The length is the entire supplied prefix, including its 300 or 600 ms of end silence. These are full-request times. The per-clip distributions are retained in `summary.json`.

| Mode | Prefix length | Requests | Median, ms | Range, ms |
| --- | --- | ---: | ---: | ---: |
| Accurate | Up to 3 s | 24 | 81.155 | 79.553 to 94.077 |
| Accurate | 3 to 4 s | 63 | 89.959 | 75.133 to 170.739 |
| Accurate | Over 4 s | 9 | 100.141 | 95.368 to 172.241 |
| Fast | Up to 3 s | 24 | 85.539 | 64.003 to 136.698 |
| Fast | 3 to 4 s | 63 | 81.538 | 65.626 to 235.739 |
| Fast | Over 4 s | 9 | 110.501 | 78.874 to 286.287 |

These short prefixes span 2.640 to 4.326 seconds. Timing varies with clip content and host load; the table does not establish linear scaling or 90-second performance. Request time includes preparation and actual finalized recognition. No end-to-end speedup is claimed.

### Trigger replacement

Eligible runs keep an in-memory PCM copy up to 90 seconds. The copy stops and clears when a buffer would exceed the cap, when capture ends, or when the run is cancelled or fails. Each quiet period starts at most one offline Apple pass after 300 ms. The pass uses the run's locale, speech vocabulary, and recognition mode through the existing transcriber seam. A separate finalized analyzer reads one coalesced snapshot as fast as possible. Loud audio cancels a pending pass. Another quiet period can start a new pass; identical corrected input keeps the existing transform attempt.

The live-partial trigger is removed. None of the 9 mismatches at +300 ms or the 6 mismatches at +600 ms had a matching live partial at least 300 ms before release. Thus this matrix provides no additional opportunity for the old stability trigger on an offline miss. Live transcript display remains independent. The release path still requires corrected final input with identical UTF-8 bytes and uses the existing atomic commit path on a hit. No speculative pass or transform writes audio, history, or the clipboard.

### Coalesced snapshot check

The implementation submits one coalesced PCM snapshot to the transcriber. A second set of 192 offline requests used `--whole-buffer` to match that input shape and reused the 96 realtime references. All 192 completed without errors or timeouts, and every trimmed result was byte-identical to its corresponding 20 ms feed result. The equality table and gate decision therefore remain unchanged. The two sets contain 480 distinct recognition requests in total. The second set ran after the Debug build completed. No tests or build ran during either measurement set.

The coalesced full-request latency is below. The larger first-request outlier is retained, not discarded. These times include real recognition and result collection, but do not measure contention with a simultaneous live analyzer.

| Mode | Prefix length | Requests | Median, ms | Range, ms |
| --- | --- | ---: | ---: | ---: |
| Accurate | Up to 3 s | 24 | 75.663 | 71.771 to 84.491 |
| Accurate | 3 to 4 s | 63 | 82.660 | 67.796 to 423.133 |
| Accurate | Over 4 s | 9 | 91.625 | 87.745 to 178.986 |
| Fast | Up to 3 s | 24 | 79.424 | 60.664 to 88.435 |
| Fast | 3 to 4 s | 63 | 73.071 | 61.295 to 174.755 |
| Fast | Over 4 s | 9 | 77.962 | 74.861 to 168.676 |

The matching-shape raw data and per-clip distributions are in `.cache/recognition-eval/offline-2026-11-05/whole-buffer-combined.jsonl` and `whole-buffer-summary.json`. Reproduce by adding `--whole-buffer` to the two prefix commands above, keeping the mode, clip set, and repetition identifiers paired with the realtime references.

### Final verification

All 480 distinct recognition requests produced nonempty text and at least one final segment. For coalesced prefixes, median analyzer finalization was 56.016 ms in accurate mode and 52.944 ms in fast mode. Median setup was 24.468 and 22.029 ms respectively; median feed was 0.060 and 0.068 ms. These observed stages account for most of the short-clip wall time. No claim is made about hardware utilization or a production speedup.

| Check | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| First focused run | 26 | 1 | 0 |
| Focused rerun | 27 | 0 | 0 |
| Final whole isolated suite, 680 tests | 675 | 0 | 5 |
| Recognition harness Python tests | 18 | 0 | 0 |
| Unsigned Debug target build | Passed | 0 | 0 |
| `git diff --check` | Passed | 0 | 0 |

The initial failure was the cap fixture's wait exhausting its fixed number of yields while the level scan processed a 90-second buffer. The fixture now uses the capture format and an explicit five-second readiness timeout; the injected business clock still controls the quiet deadline. The cap test passed in the focused rerun and final suite. No test-host retry or test timeout occurred. The whole suite includes the concurrently added settings tests. Xcode reported its existing CoreSimulator version warning; the macOS build and tests succeeded.

The five opt-in skips are `ReleasePathTimingTests.levelTapAndMainActorHops`, `ReleasePathTimingTests.quietReleaseCostAgainstAMenuStop`, `AppleOnDeviceTransformerTests.availableModelSmokeTransformsShortPhrase`, `MishearingProbeRealTests.publicTermsWithInstalledAssetsOnly`, and `MishearingProbeRealTests.publicCarrierSynthesisStaysInMemory`.

Commands:

```sh
xcodegen
SYRUP_TEST_ROOT=$(mktemp -d /tmp/syrup-offline.XXXXXX) script/test-isolated.sh \
  -only-testing:SyrupTests/PauseTransformationTests \
  -only-testing:SyrupTests/PauseTransformationPolicyTests \
  -only-testing:SyrupTests/PauseAudioCaptureTests
# Reuse that owned root for the focused rerun and final whole suite.
SYRUP_TEST_ROOT=<owned-root> script/test-isolated.sh
xcodebuild -scheme Syrup -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath <owned-/tmp/syrup-offline-build-directory>
python3 -B -m unittest discover -s script/recognition-eval -p 'test_*.py'
git diff --check
```

The tests cover the 299/300 ms boundary without any live transcript, loud-audio cancellation, another quiet period, input deduplication and replacement, frozen recognition configuration, empty and failed offline passes, byte-exact misses, hidden cue and transcript, cap behavior, snapshot ownership, copy cleanup, exclusion of ineligible runs, and existing delivery/cancellation behavior. Temporary build and test roots were removed after retaining logs and xcresult summaries under ignored `checks/`. No production app, hotkeys, microphone, or real clipboard were used. No model was downloaded.

### Replacement architecture paragraph

Early transformation is a default-off optimization for Apple-only voice dictation with a local transformation provider. Eligible runs keep up to 90 seconds of audio in memory. After 300 ms of quiet, a separate Apple pass finalizes a snapshot using the run's locale, speech vocabulary, and recognition mode. A nonempty corrected transcript starts an atomic transform with a fresh provider instance. Loud audio cancels pending transcription; another quiet period can try again. Identical input keeps the existing attempt. Release reuses a result only when the corrected final transcript has identical UTF-8 bytes. Mismatch or failure follows the ordinary path. The audio copy is cleared at release, cancellation, failure, or the duration cap. Existing quiet, attempt, outcome, and delivery metrics remain unchanged.

### Replacement product paragraph

Transform on pause can reduce the wait after releasing the dictation key. It is off by default and works with Apple speech recognition and a local transformation provider. After 300 ms of silence, Syrup transcribes the audio captured so far and starts processing it in the background. Results appear only after release and only when they match the final corrected transcript. Speaking again can start another attempt after the next pause. The temporary audio copy stays in memory and is discarded when capture ends or exceeds 90 seconds. Unsupported runs keep their existing behavior.

### Open risks

Real microphone hit rates, real provider latency, concurrent live/offline Apple contention, and long-prefix recognition latency remain unmeasured. The 90-second cap and cleanup are covered with fixtures, not a 90-second real Apple decode. Vocabulary-on equality and macOS 26 runtime behavior are unverified; the measured host runs macOS 27. Sequential synthetic equality is evidence for the gate, not proof of an end-to-end improvement. A separate Apple pass can add local CPU and memory work on a miss. No production release-to-clipboard improvement is claimed.
