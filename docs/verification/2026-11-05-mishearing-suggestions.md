# Mishearing suggestions verification

Personal identifiers and machine paths in this record use illustrative placeholders.

## Result

The probe engine and observable model are implemented. Focused fake-based tests and the full isolated suite pass. The unsigned production target build also passes. Four real system-voice synthesis samples produced in-memory PCM. Real recognition remains unverified: both requested locales have installed assets, but the isolated test host lacks Speech authorization. All 12 public-term probes returned `speechPermissionRequired` without requesting permission.

Worktree: `/path/to/syrup/feature-worktree`.
Host: Apple silicon MacBook Pro, macOS 27.0.1 (26A434), Xcode 27.2 (27B52). The deployment target remains macOS 26. No production app, microphone, real hotkey, asset download, or network service was used. Dependencies came from the existing local SwiftPM checkout.

## Method

`SystemMishearingSynthesizer` bridges `AVSpeechSynthesizer.write` into an `AsyncThrowingStream`, copies callback buffers, and retains audio only in memory. Each synthesis operation is limited to 30 seconds of wall time and 30 seconds of audio. Voice selection prefers an exact normalized locale, then the same language, higher quality, and a stable identifier order. Each locale uses at most two distinct voices.

Portuguese and English probes use neutral carrier sentences. Extraction matches the complete prefix and suffix by Unicode words, ignoring case, accents, and punctuation. It preserves the spelling and interior punctuation of the heard term. Missing or changed carrier words discard the sample. Other languages use the term alone.

`AppleMishearingRecognizer` joins each clip's PCM buffers before submitting one input buffer to the production `AppleTranscriber`. This prevents an eager offline producer from overflowing the production analyzer's bounded queue. The existing converter supplies the analyzer's required format. Recognition has a 60-second timeout. The probe uses `AppSettings.composedSpeechVocabulary`, including personal terms and the configured common technical terms.

`AppleTranscriber` has an `allowAssetPreparation` option, defaulting to true for existing callers. The probe passes false. This mode rechecks installed assets, does not use a stale installed-locale cache, and never requests Speech authorization or starts asset preparation. The probe also checks availability before synthesis.

The model processes terms sequentially, cancels on foreground activity, and rejects starts during foreground activity. Cancellation keeps completed results and restores the previous state of the interrupted term. Results from renamed or removed terms are discarded. Acceptance merges into the current term through `AppSettings.updateGlossaryTerm`; dismissal and probe results stay in memory. Optional Parakeet probing is not implemented.

## Test results

| Check | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Focused suites | 15 test functions, 31 expanded cases | 0 | 0 |
| Opt-in real suite | 2 test functions | 0 | 0 |
| Full isolated suite | 618 test functions, 940 expanded cases | 0 | 5 |

The full run discovered 623 test functions across 79 suites. Its five skipped functions were the two opt-in real probes, two existing release-timing tests, and the existing unavailable Apple on-device model smoke test. The real suite passed its synthesis and availability assertions; that does not establish recognition accuracy. Twelve recognition probes were unavailable, not successful recognitions.

Focused coverage includes carrier table cases, accents, punctuation without spaces, exact-match normalization, deduplication, voice ordering and fallback, missing voices and assets, sample failures, vocabulary forwarding, 300-buffer PCM preservation, model progress, cancellation, foreground blocking, persistence, memory-only dismissal, and stale-result rejection.

The first focused build failed to compile because a test helper's closure lacked explicit main-actor isolation. That helper was corrected before the passing run. No test-host launch or termination retry was needed. An initial real-suite invocation skipped its tests because Xcode did not forward the bare environment variable; `TEST_RUNNER_SYRUP_MISHEARING_REAL=1` enabled the subsequent real runs.

## Public-term recognition probes

All rows had zero extracted samples, zero exact matches, no heard forms, and the typed reason `speechPermissionRequired`. These durations measure availability checks, not recognition speed. Both locales offered two selected voices and passed the installed-asset check before the authorization check.

| Public term | pt-BR check, ms | en-US check, ms |
| --- | ---: | ---: |
| PostgreSQL | 46.23 | 68.04 |
| Kubernetes | 46.98 | 47.56 |
| Grafana | 49.42 | 110.14 |
| TypeScript | 48.70 | 46.72 |
| Nginx | 49.85 | 68.87 |
| OAuth | 47.85 | 47.00 |

The separate real synthesis check spoke the Grafana carrier with each selected voice:

| Locale | Voice index | PCM frames | Buffers | Wall time, ms |
| --- | ---: | ---: | ---: | ---: |
| pt-BR | 1 | 35,312 | 191 | 420.54 |
| pt-BR | 2 | 35,311 | 191 | 114.69 |
| en-US | 1 | 36,607 | 198 | 115.56 |
| en-US | 2 | 36,607 | 198 | 71.53 |

These are individual smoke samples, not a benchmark. Framework diagnostics included `unsafeForcedSync`, audio-unit service invalidation, and zero-length terminal audio-buffer warnings. Both real test functions still completed successfully. Xcode also reported an outdated CoreSimulator service, which did not prevent macOS builds or tests.

## Reproduction commands

The isolated script creates an inert app host with bundle identifier `org.syrup.SyrupIsolatedTests`. The following commands use only an existing package checkout. Each temporary directory is owned by this run and removed after evidence collection.

```sh
probe_root=$(mktemp -d /tmp/syrup-probe.XXXXXX)
package_root=/path/to/SourcePackages
xcodegen
SYRUP_TEST_ROOT="$probe_root" script/test-isolated.sh \
  -only-testing:SyrupTests/MishearingProbeTextTests \
  -only-testing:SyrupTests/MishearingProbeEngineTests \
  -only-testing:SyrupTests/MishearingSuggestionModelTests \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -clonedSourcePackagesDirPath "$package_root"
TEST_RUNNER_SYRUP_MISHEARING_REAL=1 SYRUP_TEST_ROOT="$probe_root" \
  script/test-isolated.sh -only-testing:SyrupTests/MishearingProbeRealTests \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -clonedSourcePackagesDirPath "$package_root"
SYRUP_TEST_ROOT="$probe_root" script/test-isolated.sh \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -clonedSourcePackagesDirPath "$package_root"
build_root=$(mktemp -d /tmp/syrup-probe-build.XXXXXX)
xcodebuild -scheme Syrup -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  -derivedDataPath "$build_root" \
  -disableAutomaticPackageResolution -skipPackageUpdates \
  -clonedSourcePackagesDirPath "$package_root"
rm -rf "$probe_root" "$build_root"
```

The opt-in test checks `SYRUP_MISHEARING_REAL == "1"` inside the test process. Xcode's `TEST_RUNNER_` prefix forwards this value. The actual test root was `/tmp/syrup-probe.3stgXt`; the unsigned production build used `/tmp/syrup-probe-build.7TVYmL`. Both temporary directories were removed after verification. Test results were read with `xcrun xcresulttool get test-results summary --path <result.xcresult> --format json`.

## UI integration API

All types below are internal to the Syrup module. No view or pane was changed. `SyrupApp` owns one model, passes the existing foreground-activity signal to `setForegroundActive`, and attaches `.environment(mishearingSuggestions)` to the Settings scene's root view. A descendant reads it with `@Environment(MishearingSuggestionModel.self) private var suggestions`.

```swift
@MainActor @Observable
final class MishearingSuggestionModel {
    init(settings: AppSettings, engine: any MishearingProbing)

    var states: [UUID: TermState] { get }
    var progress: Progress { get }
    var isRunning: Bool { get }
    var isForegroundActive: Bool { get }
    var canProbe: Bool { get }
    var localeIDs: [String] { get }

    func state(for termID: UUID) -> TermState
    func probe(termID: UUID) async
    func probeAll() async
    func cancel()
    func setForegroundActive(_ active: Bool)
    @discardableResult func accept(_ form: String, for termID: UUID) -> Bool
    func dismiss(_ form: String, for termID: UUID)

    struct Progress: Equatable, Sendable {
        let done: Int
        let total: Int
    }
    enum TermState: Equatable, Sendable {
        case idle
        case running
        case results(MishearingProbeResult)
        case recognizedCorrectly(MishearingProbeResult)
        case unavailable([MishearingProbeLocaleIssue])
        case failed(MishearingProbeFailure)
    }
}
```

Use `state(for:)` for display; it hides stale dictionary entries after a term is renamed or deleted. Await probe methods in a view-owned `Task`. A start while busy, while foreground activity is active, or without voice locales is a no-op. `cancel()` requests cancellation; `isRunning` becomes false after cleanup. No automatic restart occurs. `progress.done` counts completed terms, including unavailable or failed terms, and excludes an interrupted term.

`localeIDs` reflects the current workflow list: active voice workflow first, then other voice workflows, deduplicated by BCP-47 identifier and capped at three. A run snapshots those locales and its vocabulary.

```swift
struct MishearingProbeResult: Equatable, Sendable {
    var heardForms: [String]
    let sampleCount: Int
    let exactMatchCount: Int
    let discardedSampleCount: Int
    let failedSampleCount: Int
    let unavailableLocales: [MishearingProbeLocaleIssue]
    var recognizedCorrectly: Bool { get }
}
struct MishearingProbeLocaleIssue: Equatable, Sendable {
    let localeID: String
    let reason: MishearingProbeUnavailableReason
}
enum MishearingProbeUnavailableReason: Equatable, Sendable {
    case noVoice, speechModelNotInstalled, speechPermissionRequired, unsupportedLocale
}
enum MishearingProbeFailure: Error, Equatable, Sendable {
    case synthesisFailed, recognitionFailed, timedOut, noUsableSamples
}
```

`sampleCount` counts successfully extracted samples; discarded carrier transcripts and failed operations have separate counts. `exactMatchCount` counts extracted samples equal to the term after case, whitespace, and edge-punctuation normalization. Accents remain significant. `recognizedCorrectly` requires at least one extracted sample, every extracted sample exact, and no discarded samples, failures, or unavailable locales. Removing the last suggestion leaves `.results` with an empty `heardForms` array; it never changes a misrecognition into a correct-recognition claim.

`accept` only accepts an offered form for an unchanged, existing term and returns whether it appended the hint. `dismiss` hides an offered form for the lifetime of this model, including subsequent probes of that term. Renaming a term resets its dismissals when it is probed again.

The injectable engine API is `@MainActor protocol MishearingProbing { func probe(term: GlossaryTerm, localeIDs: [String], vocabulary: [String]) async throws -> MishearingProbeResult }`. The live initializer is `MishearingProbeEngine(synthesizer: any MishearingSynthesizing, recognizer: any MishearingRecognizing)`. `SystemMishearingSynthesizer()` and `AppleMishearingRecognizer(assetManager:)` supply the live implementations. Tests replace both protocols and never call real speech services.

## Recognition through the evaluation harness

The isolated host cannot transcribe without Speech authorization, so an evaluation checked what Apple's recognizer hears with `script/recognition-eval.sh`, which needs no permission. Each public sample term was spoken inside the probe's carrier sentence by two default macOS voices per locale (`say`, 24 kHz 16-bit WAV, outside every Git worktree), then run through `--engine apple --vocabulary both --repeats 1`. Vocabulary on and off gave identical hypotheses for all 24 clips, as in the earlier recognition evaluation. This checks the method and the carriers, not the app's synthesis-to-recognition code path, which still needs a live check in the app.

| Term | en-US, Samantha | en-US, Eddy | pt-BR, Luciana | pt-BR, Eddy |
| --- | --- | --- | --- | --- |
| PostgreSQL | post-Ger SQL | post 3 SQL | postigre SQL | fotos |
| Kubernetes | Guber needs | Uber needs | cubernetes | Uberetes |
| Grafana | Graffana | profile | Grafana | carrier lost |
| TypeScript | typescript | type script | tapecript | o tipo de crime de |
| Nginx | ginks | carrier lost | j | os rinques |
| OAuth | go off | those | olout | o áudio |

"Carrier lost" means the recognizer changed a carrier word, so extraction discards the sample. Samantha and Luciana produced the useful mishearings. Eddy, an Eloquence voice, produced several everyday words ("those", "profile", "fotos", "o áudio"). Approved as hints, those could pull a provider into rewriting ordinary sentences. Three changes followed:

- Voice choice skips novelty and personal voices and, at equal quality, prefers the `com.apple.voice.*` voices (Samantha, Luciana) over Eloquence and older voices. Before this, a Mac with only default voices chose two Eloquence voices, and novelty voices such as Bubbles were reachable.
- A heard form needs at least two letters and at most two words more than the term, which removes "j" and "o tipo de crime de".
- Forms made only of correctly spelled words in the language that produced them are listed in `MishearingProbeResult.everydayForms`, using the system spelling dictionaries, so the UI can warn before the user accepts one. On the table above this flags "go off", "Uber needs", "profile", "type script", "those", "fotos", "os rinques", and "o áudio", and keeps every other form unflagged.

## Proposed documentation text

For ARCHITECTURE.md:

Mishearing suggestions use system voices to synthesize each glossary term in memory and pass the audio through AppleTranscriber with the same speech vocabulary as dictation. Probes require installed locale assets and existing Speech authorization, and never start downloads or permission requests. MishearingSuggestionModel selects up to three voice-workflow locales and probes terms sequentially, with at most two voices per locale. It cancels when foreground dictation starts. English and Portuguese samples use neutral carriers whose complete boundaries must match before a heard form is extracted. Results and dismissals stay in memory. Accepting a suggestion updates the term through AppSettings, so the existing glossary prompt includes the approved hint for every provider. Parakeet probing is not implemented.

For PRODUCT.md:

Glossary terms can be checked locally for possible mishearings using installed system voices and speech models. Suggestions require approval before they become glossary hints. A check can report that a term was recognized correctly, return up to three suggestions, or explain that a voice, model, or Speech authorization is unavailable. Checks stop when dictation starts. Synthetic voices do not establish how well the recognizer understands the user's voice. This implementation provides the engine and model; the settings controls are a separate UI task.

## Remaining verification

Real recognized forms and end-to-end carrier extraction remain unverified because the isolated host has no Speech authorization. There is no claim of real-voice accuracy or recognition speed. Parakeet probing, manual Settings interaction, and production hotkeys were outside this implementation. No permission settings were changed to expand coverage.
