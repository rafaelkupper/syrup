import Foundation
import Testing
@testable import Syrup

@Suite(.enabled(if: ProcessInfo.processInfo.environment["SYRUP_MISHEARING_REAL"] == "1"))
@MainActor
struct MishearingProbeRealTests {
    @Test func publicCarrierSynthesisStaysInMemory() async throws {
        let synth = SystemMishearingSynthesizer()
        for locale in ["pt-BR", "en-US"] {
            let voices = MishearingProbeVoice.select(from: synth.availableVoices(), localeID: locale)
            for voice in voices {
                let start = ContinuousClock.now
                let buffers = try await synth.synthesize(MishearingCarrier(localeID: locale).sentence(term: "Grafana"), voice: voice)
                let frames = buffers.reduce(0) { $0 + Int($1.frameLength) }
                print("probe_synthesis locale=\(locale) frames=\(frames) buffers=\(buffers.count) duration=\(start.duration(to: .now))")
                #expect(frames > 0)
            }
        }
    }

    @Test func publicTermsWithInstalledAssetsOnly() async throws {
        let synth = SystemMishearingSynthesizer()
        let recognizer = AppleMishearingRecognizer(assetManager: TranscriberAssetManager())
        let engine = MishearingProbeEngine(synthesizer: synth, recognizer: recognizer)
        let terms = ["PostgreSQL", "Kubernetes", "Grafana", "TypeScript", "Nginx", "OAuth"]
        let glossary = GlossaryList(terms: terms.map { GlossaryTerm(term: $0) })
        let vocabulary = AppSettings.composedSpeechVocabulary(glossary: glossary, includeCommonTechTerms: true)
        for locale in ["pt-BR", "en-US"] {
            let voices = MishearingProbeVoice.select(from: synth.availableVoices(), localeID: locale)
            print("probe_inventory locale=\(locale) voices=\(voices.count) unavailable=\(String(describing: await recognizer.availability(localeID: locale)))")
            for term in glossary.terms {
                let start = ContinuousClock.now
                let result = try await engine.probe(term: term, localeIDs: [locale], vocabulary: vocabulary)
                let duration = start.duration(to: .now)
                // This opt-in fixture contains public sample terms only.
                print("probe_public locale=\(locale) term=\(term.term) forms=\(result.heardForms) samples=\(result.sampleCount) exact=\(result.exactMatchCount) discarded=\(result.discardedSampleCount) failed=\(result.failedSampleCount) unavailable=\(result.unavailableLocales) duration=\(duration)")
                #expect(result.failedSampleCount == 0)
            }
        }
    }
}
