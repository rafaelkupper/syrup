# Parakeet Ultra and Redux, 2026-11-04

Personal identifiers and machine paths in this record use illustrative placeholders.

the maintainer chose Parakeet Ultra to replace Parakeet v3 and Parakeet Redux as the small download, after [the Portuguese comparison](2026-11-03-portuguese-models.md). Measured on Mac16,7, macOS 27.0.1, FluidAudio 0.18.0, through `script/recognition-eval.sh` unless noted.

## Bars now come from real recordings

The model list's bars had been set from 24 synthetic `say` clips. Redux broke down on those voices: "Ela preparou uma sopa quente para o jantar" came out as "preparoć opa kara oje tar", and it missed 32% of Portuguese words, against 5.2% on real recordings. Synthetic voices would have ranked it unfairly, so every model was measured again on real ones.

Accuracy: the first 200 test clips of FLEURS `en_us` (4,202 words) and `pt_br` (4,829 words), from `FluidInference/fleurs-full`, CC-BY-4.0, one offline pass each. FLEURS writes numbers as digits, so a model that spells them out is charged for it.

| Model | Portuguese | English | Mean | Bar |
| --- | ---: | ---: | ---: | ---: |
| Parakeet Ultra | 4.15% | 5.07% | 4.61% | 5 |
| Parakeet Redux | 5.24% | 6.61% | 5.93% | 4 |
| Parakeet Unified EN | n/a | 5.17% | 5.17% | 4 |
| Apple | 6.78% | 7.67% | 7.23% | 3 |
| Canary 180M Flash | n/a | 8.42% | 8.42% | 3 |
| Nemotron Streaming 3.5 | 8.47% | 10.62% | 9.55% | 2 |

Speed: the wait from release to final text on one long clip per language, made by joining six FLEURS clips with 300 ms gaps (72.4 s English, 67.9 s Portuguese), fed in real time, two runs.

| Model | English wait, ms | Portuguese wait, ms | Mean | Bar |
| --- | --- | --- | ---: | ---: |
| Parakeet Unified EN | 46, 42 | n/a | 44 | 5 |
| Nemotron Streaming 3.5 | 48, 57 | 54, 52 | 53 | 5 |
| Canary 180M Flash | 116, 121 | n/a | 119 | 4 |
| Apple | 245, 245 | 162, 160 | 203 | 3 |
| Parakeet Ultra | 265, 260 | 256, 256 | 259 | 2 |
| Parakeet Redux | 728, 734 | 530, 547 | 635 | 1 |

Accuracy bars use the mean over the languages a model supports: 5 at or below 5%, then one step per 2 points, so 4 at or below 7%, 3 at or below 9%, 2 at or below 11%, and 1 above. Speed keeps the earlier steps: 5 at or below 75 ms, 4 at or below 150 ms, 3 at or below 225 ms, 2 at or below 300 ms, and 1 above. A clip of over a minute is the worst case for Parakeet, which decodes up to 60 seconds at release. On the 200 short clips, Ultra finished in 53 to 60 ms at the median, and Redux in 80 ms on the clips below.

On the synthetic clips, for comparison with the old bars: v3 4.2% English and 13.1% Portuguese, Ultra 5.2% and 14.1%, Redux 10.4% and 32.3%. v3's figures matched the earlier run exactly. On the synthetic long clips Ultra waited 254 to 289 ms and v3 248 to 277 ms.

## Where Redux runs

Redux gave the same text on the Neural Engine and on the GPU in 58 of 60 clips, with the same errors. The Neural Engine finished sooner on every measure:

| First 60 FLEURS pt_br clips | Median | p90 | Max |
| --- | ---: | ---: | ---: |
| Ultra, Neural Engine | 61 ms | 106 ms | 115 ms |
| Redux, Neural Engine | 80 ms | 155 ms | 162 ms |
| Redux, GPU | 143 ms | 252 ms | 266 ms |

On the synthetic long clips the GPU waited 625 to 1,243 ms and the Neural Engine 535 to 954 ms. The GPU's advantage is load time: its first load took 0.6 s, while the Neural Engine compiles Redux's 2-bit encoder for minutes the first time and took 11.5 s on later loads in the evaluation. Syrup uses the Neural Engine, FluidAudio's default, because the wait after each dictation matters more than a one-time load, and Apple covers dictation until the model is ready.

FluidAudio's `AsrModels.download` compiles each model for the Neural Engine as part of the download. Syrup downloads into a staging folder and then moves the model, which would compile it twice, so `ParakeetEngine` fetches the files with `ModelHub.download` and compiles once at load. FluidAudio reports that download as the first half of a download-and-compile, so Syrup doubles its fraction.

## Sizes

Bytes on disk after download: Ultra 632,314,500 (632 MB), Redux 220,455,773 (220 MB). v3 was 483,257,242; Syrup had shown 460 MB.

## Replacing v3

- Workflows saved with `parakeet_v3` decode as Parakeet Ultra and are saved as `parakeet_ultra` on the next write. A test decodes a 0.9 workflow list.
- At launch `SpeechModelCatalog.replaceRetiredParakeetV3()` deletes `SpeechModels/parakeet-tdt-0.6b-v3` and starts the Ultra download. Tests check that it deletes only that folder, starts the download, and does nothing when the folder is absent.

## End to end through Syrup's code

A separate `org.syrup.SyrupUIVerify` host ran `SpeechModelCatalog.live` on temporary storage that held a stand-in `parakeet-tdt-0.6b-v3` folder, and called `replaceRetiredParakeetV3()` as the app does at launch. The first try showed the download failing after the files had arrived: `ParakeetEngine.download` wrote straight into the model folder instead of the staging folder. The unit tests use fake downloads and did not catch it. After the fix:

| Step | Ultra | Redux |
| --- | --- | --- |
| Start | Stand-in v3 folder gone, download started without a click | Download pressed |
| Ready after | 49.7 s, of which loading 7.9 s | 401.7 s, of which loading 363.3 s |
| Progress | 0 to 90% in tenths, then loading | Same |
| FLEURS en_us_0000, 10.6 s | Right, 95 ms | Right ("west" lowercase, "25-30"), 119 ms |
| FLEURS pt_br_0000, 17.8 s | Right, 170 ms | "vinte", "Bíber", and "tivesse" for "estivesse", 214 ms |
| Real long clip, 67.9 s pt | 401 ms | 557 ms |
| Relaunch, ready after | 0.7 s | 11.4 s |
| Delete | Folder gone, the other kept | Folder gone |

These transcription times include feeding the whole clip at once, not a real-time wait. Ultra's 7.9 s first load is the Neural Engine compile at its final path. Redux's first load compiled for 6 minutes, during which its workflows use Apple and say the model is still loading.

The model list rendered in light and dark with both new rows, their sizes, and the new bars and footer.

## Tests

603 Swift tests in 75 suites passed in the isolated runner. New ones cover the `parakeet_v3` decode, the v3 folder replacement and its absence, both models' languages, their folders against FluidAudio's, and Redux's live preview coming from Apple.

## Not checked

- A real microphone, real dictation, or the production app updating from 0.9. The update path ran in the host with a stand-in folder.
- Redux's first load on slower Macs. FluidAudio measured 320 to 1,585 seconds on Apple silicon.
- Intel Macs, where both are hidden.
