# Release path verification

## Result

**Update after this measurement.** A release adds no buffer wait when the last buffer before release was already quiet. The figures below apply only when the last buffer before release was still loud. The zero-wait path is checked by `releaseAfterAQuietBufferStopsWithoutWaiting` with a manual clock, not on a real microphone.

A quiet release now waits for the next audio buffer, then spends about 0.09 ms on tail work. With a 48 kHz microphone the buffer wait is between 0 and 85.3 ms, 42.7 ms on average. That range is arithmetic from the 4096-frame capture buffer. The microphone was off limits, so no hardware measured it. The 0.09 ms is the median of five Release runs, each with 200 interleaved pairs.

The isolated suite at the final head runs 431 tests in 48 suites. 428 pass, 3 skip, and none fail. The skips are the two timing tests below, which run only on request, and the existing on-device smoke test, which needs a ready model. The baseline at `f712b13` ran 404 tests in 42 suites.

The machine is a Mac16,7 with an Apple M4 Pro and 14 cores, on macOS 27.0.1 (26A434). Load averages stayed between 2.2 and 6.2 during the runs.

## Commands

The full suite and the Debug timing runs use the isolated host.

```sh
SYRUP_TEST_ROOT=/tmp/syrup-release-path-tests script/test-isolated.sh
TEST_RUNNER_SYRUP_RELEASE_TIMING=1 SYRUP_TEST_ROOT=/tmp/syrup-release-path-tests script/test-isolated.sh -only-testing:SyrupTests/ReleasePathTimingTests
```

The Release timing runs reuse the copy that the isolated script prepares.

```sh
cd /tmp/syrup-release-path-tests
TEST_RUNNER_SYRUP_RELEASE_TIMING=1 xcodebuild -scheme Syrup -configuration Release -destination 'platform=macOS' -derivedDataPath /tmp/syrup-release-path-tests/build-release test -only-testing:SyrupTests/ReleasePathTimingTests ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO
```

The final suite log is `/tmp/syrup-release-final-full.log`. The timing logs are `/tmp/syrup-release-timing-release-1.log` through `-5.log` and `/tmp/syrup-release-timing-debug-4.log` through `-6.log`. Their summary rows are in `2026-11-01-release-path-timings.tsv`.

## Quiet release cost

`ReleasePathTimingTests.quietReleaseCostAgainstAMenuStop` drives revision runs through `AppState` with a fake recorder. It alternates two stops 200 times each. A hotkey stop releases in hold mode, then yields one prebuilt -60 dBFS buffer, so the tail ends on that buffer. A menu stop uses Finish revision, which skips the tail. Both read `release_to_recorder_stopped` with `ContinuousClock` at the metric's begin and end. Each stop waits 10 ms first, so the level tap starts idle, as it does between 85 ms buffers in production.

| Release run | Hotkey stop with tail | Menu stop | Paired difference | Difference p95 | Difference max |
| --- | --- | --- | --- | --- | --- |
| 1 | 0.160 ms | 0.095 ms | 0.058 ms | 0.119 ms | 0.371 ms |
| 2 | 0.187 ms | 0.091 ms | 0.093 ms | 0.152 ms | 0.259 ms |
| 3 | 0.184 ms | 0.099 ms | 0.085 ms | 0.136 ms | 0.239 ms |
| 4 | 0.187 ms | 0.093 ms | 0.090 ms | 0.155 ms | 0.249 ms |
| 5 | 0.188 ms | 0.096 ms | 0.088 ms | 0.184 ms | 0.378 ms |

The first three columns are medians. The median of the five paired medians is 0.088 ms.

### What limits it

The buffer wait dominates. `AudioQueueCaptureSession.bufferFrameCount` is 4096, and the first buffer after a release arrives when the current one fills. The wait is therefore uniform between 0 and one buffer period. A period is 85.3 ms at 48 kHz, 92.9 ms at 44.1 kHz, 170.7 ms at 24 kHz, and 256 ms at 16 kHz. At 16 kHz the 200 ms deadline caps the wait. These periods come from the buffer size, not from a recording.

The tail work is thread handoffs, not computation. In the same Release runs, RMS over 4096 frames takes 0.003 ms. A warm level tap reports a level 0.007 to 0.010 ms after the yield. A warm hop from a detached task to the main actor takes 0.0045 ms. Those parts add up to under 0.02 ms. The rest of the 0.09 ms is inferred to be waking idle threads after the 10 ms gap. The menu path shows the same effect without any tail. In Debug runs without the gap its median was 0.017 ms, and with the gap it was 0.083 ms.

### What else the number could be measuring

- **Debug code.** Debug RMS takes 0.27 ms, about 90 times the Release cost, and the Debug paired difference after idle is 1.9 ms. Production ships Release builds, so the Release rows carry the claim. The Debug rows stay in the TSV.
- **Building the test buffer.** The harness builds the quiet buffer before the timed window. An earlier version built it inside the window, and the Debug difference moved by about 0.02 ms (logs `-debug-1` to `-3`).
- **A busy tap.** Without the 10 ms gap, the Debug difference was about 0.3 ms above the warm tap and hop costs, which matches one Debug RMS. The inferred cause is a tap still measuring the previous buffer when the quiet buffer arrived. Production buffers arrive 85 ms apart, so the gap matches production.
- **The deadline.** The manual clock never advances after a release, so no hotkey run could end at the 200 ms deadline.
- **Errors.** Every iteration waits for its own clipboard write before the next starts, and the test asserts 200 samples per side.
- **Harness differences.** The fake recorder yields from the main actor rather than the AudioQueue callback queue. The Release test build sets `ENABLE_TESTABILITY` and turns hardened runtime off.

### Does it matter

The product target is under 3 seconds from release to clipboard. The mean buffer wait at 48 kHz is 1.4% of that target and the worst case is 2.8%. The tail work is under 0.01%. Speech finalization took 110 to 118 ms in the plan's 2026-11-01 probe on synthetic clips. Against that, the mean buffer wait adds roughly 35 to 40% to `release_to_transcript` on a quiet release. That figure is an inference from two separate measurements, not an end-to-end run.

Two changes could shrink the buffer wait. Stopping at once after a quiet buffer is now implemented. Smaller capture buffers are not implemented.

- Smaller capture buffers. At 1024 frames the wait at 48 kHz drops to between 0 and 21.3 ms. Callbacks, level computations, and stream handoffs become four times as frequent, each measured here in microseconds. Callback stability on real devices would need a hardware check.
- Finish at once when the last buffer before the release was quiet. A release after a pause would then add nothing. A word that starts within one buffer of the release, after a pause, would be cut as it is today.

## Gate rationale

The tail ends on the first post-release buffer whose RMS is under -45 dBFS. Hex treats -50 dBFS as near silence; that figure comes from the brief and was not checked against Hex here. The gate sits 5 dB higher on purpose. The decision uses a whole buffer's RMS, so a room with a noise floor between -50 and -45 dBFS never passes a -50 gate. Every release there would wait the full 200 ms. At -45 those releases end on the first buffer.

A gate set too high costs little. The tail always keeps the first post-release buffer, which holds the audio up to that buffer's boundary, and `finish()` then flushes the partial buffer. Every tail therefore captures more audio than the old immediate stop. The gate decides only whether to keep listening longer. Real room and speech levels were not measured, because the microphone was off limits.

## Which stops take a tail

- A hold release or a toggle-off press, for dictation and revision, takes the tail only when the last buffer before release was not quiet. Otherwise it stops at once.
- Finish revision from the menu, the maximum-duration guard, and failures stop at once. A failure during a tail ends it at once.
- Esc stops through the cancel path with no tail, during recording or during a tail.
- A hold released less than 300 ms after the press cancels with no tail, for dictation and revision.
- Selected text runs never record.

## Other checks

- `ProcessInfo.beginActivity(options: .userInitiated, reason: "Syrup is processing a request")` appears in `pmset -g assertions` as `PreventUserIdleSystemSleep named: "Syrup is processing a request"`. The probe is `/tmp/syrup-activity-probe/probe.swift`.
- `SystemLanguageModel.default` and `SystemLanguageModel(guardrails: .permissiveContentTransformations)` both report `modelNotReady` here. The probe is `/tmp/syrup-guardrails-probe/probe.swift`. Guardrail behavior is unobserved.
- A failing volume controller logs `output_volume_failed error=readFailed(-1)`, and the run still delivers.
- Temporary code mutations each failed the tests written for them, and the code was restored after each run. The mutations were a tail that never starts, a short tap that never discards, a short-tap boundary moved to 300 ms inclusive, a missing activity end, and a missing wait before the success sound.

## Unverified without a real microphone

- Final-word retention on real speech, in hold and toggle modes, for dictation and revision.
- Real buffer timing on built-in, USB, and 16 or 24 kHz Bluetooth microphones.
- Room noise and speech levels against the -45 dBFS gate, including music near the microphone.
- Output lowering on real hardware during runs, and the new Settings toggle, which was not rendered.
- The activity assertion inside the running app.
- Permissive guardrails on a Mac with a ready model.

`docs/QA.md` lists these as manual checks under "Release path checks for 2026-11-01".
