import AVFoundation
import Foundation
import Testing
@testable import Syrup

struct MishearingProbeTextTests {
    @Test(arguments: [
        ("pt-BR", "Eu falei sobre Postgres hoje.", "Postgres"),
        ("pt-BR", "Eu,falei sobre: Postgres hoje.", "Postgres"),
        ("en-US", "I—talked about OAuth today!", "OAuth"),
        ("pt_PT", "EU, FÁLEI SÓBRE: \"café\" HÓJE!", "café"),
        ("en-US", "I talked about Type Script today.", "Type Script"),
        ("en-GB", "i TALKED about: Nginx, TODAY!", "Nginx"),
        ("pt-BR", "Eu falei sobre C++ hoje.", "C++"),
        ("en-US", "I talked about foo.bar today.", "foo.bar"),
        ("de-DE", "Grafana.", "Grafana"),
        ("en-US", "I talked about today.", nil),
        ("pt-BR", "Eu pensei sobre Grafana hoje.", nil),
        ("en-US", "I talked about Grafana tomorrow.", nil),
        ("en-US", "well I talked about Grafana today.", nil),
        ("pt-BR", "Eu falei sobre Grafana hoje de manhã.", nil),
        ("en-US", "I talked about ... today.", nil),
        ("en-US", "", nil)
    ] as [(String, String, String?)])
    func extractsOnlyCompleteCarriers(_ locale: String, _ text: String, _ expected: String?) {
        #expect(MishearingCarrier(localeID: locale).extract(from: text) == expected)
    }

    @Test func normalizesAndDeduplicatesWithoutRemovingAccents() {
        let term = GlossaryTerm(term: "Café", mishearings: ["Coffee"])
        #expect(MishearingForms.suggestions([
            " café! ", "COFFEE", "Cafe", "cafe.", " Type \n Script ", "type script", "Another", "Fourth"
        ], term: term) == ["Cafe", "Type Script", "Another"])
        #expect(MishearingForms.key("Café") != MishearingForms.key("Cafe"))
    }

    @Test func picksExactLocaleThenQualityAndDistinctVoices() {
        let premiumFallback = voice("fallback", "en-GB", 3)
        let exact = voice("exact", "en-US", 1)
        let exactPremium = voice("premium", "en_US", 3)
        let other = voice("other", "pt-BR", 3)
        #expect(MishearingProbeVoice.select(from: [premiumFallback, exact, other, exactPremium, exactPremium],
                                            localeID: "en-US") == [exactPremium, exact])
        #expect(MishearingProbeVoice.select(from: [other, premiumFallback, exactPremium, exactPremium],
                                            localeID: "en-US") == [exactPremium, premiumFallback])
        #expect(MishearingProbeVoice.select(from: [other], localeID: "fr-FR").isEmpty)
    }

    @Test func skipsNoveltyVoicesAndPrefersSiriEraVoicesAtEqualQuality() {
        // Identifiers as macOS 26 reports them on a Mac with only the default voices installed.
        let bubbles = MishearingProbeVoice(id: "com.apple.speech.synthesis.voice.Bubbles", localeID: "en-US",
                                           quality: 1, isExcluded: true)
        let bahh = MishearingProbeVoice(id: "com.apple.speech.synthesis.voice.Bahh", localeID: "en-US",
                                        quality: 1, isExcluded: true)
        let fred = voice("com.apple.speech.synthesis.voice.Fred", "en-US")
        let eddy = voice("com.apple.eloquence.en-US.Eddy", "en-US")
        let samantha = voice("com.apple.voice.compact.en-US.Samantha", "en-US")
        #expect(MishearingProbeVoice.select(from: [bubbles, bahh, fred, eddy, samantha], localeID: "en-US")
            == [samantha, eddy])
        #expect(MishearingProbeVoice.select(from: [bubbles, bahh], localeID: "en-US").isEmpty)
    }
}

@MainActor
struct MishearingProbeEngineTests {
    @Test func offlineFeedCombinesBuffersWithoutDroppingFrames() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2))
        let buffers = try (0..<300).map { index in
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
            buffer.frameLength = 4
            for channel in 0..<2 {
                for frame in 0..<4 { buffer.floatChannelData![channel][frame] = Float(index * 4 + frame + channel) }
            }
            return buffer
        }
        let combined = try AppleMishearingRecognizer.combinedBuffer(buffers)
        #expect(combined.frameLength == 1_200)
        for channel in 0..<2 {
            #expect(Array(UnsafeBufferPointer(start: combined.floatChannelData![channel], count: 1_200)) ==
                    (0..<1_200).map { Float($0 + channel) })
        }
        #expect(throws: MishearingProbeFailure.self) { try AppleMishearingRecognizer.combinedBuffer([]) }
    }

    @Test func usesVocabularyAndAggregatesAcrossVoicesAndLocales() async throws {
        let synth = ProbeTestSynthesizer(voices: [voice("pt", "pt-BR"), voice("en1", "en-US"), voice("en2", "en-US")])
        let recognizer = ProbeTestRecognizer(transcripts: [
            "Eu falei sobre Postgres hoje.", "I talked about PostgreSQL today.", "I talked about POSTGRES today."
        ])
        let result = try await MishearingProbeEngine(synthesizer: synth, recognizer: recognizer)
            .probe(term: GlossaryTerm(term: "PostgreSQL"), localeIDs: ["pt-BR", "en-US"], vocabulary: ["PostgreSQL", "Other"])
        #expect(result.heardForms == ["Postgres"])
        #expect(result.sampleCount == 3)
        #expect(result.exactMatchCount == 1)
        #expect(!result.recognizedCorrectly)
        #expect(recognizer.vocabularies == Array(repeating: ["PostgreSQL", "Other"], count: 3))
        #expect(synth.texts == ["Eu falei sobre PostgreSQL hoje.", "I talked about PostgreSQL today.", "I talked about PostgreSQL today."])
    }

    @Test func missingVoicesAndAssetsNeverStartSynthesisOrRecognition() async throws {
        let synth = ProbeTestSynthesizer(voices: [voice("en", "en-US")])
        let recognizer = ProbeTestRecognizer()
        recognizer.unavailable = ["en-US": .speechModelNotInstalled]
        let result = try await MishearingProbeEngine(synthesizer: synth, recognizer: recognizer)
            .probe(term: GlossaryTerm(term: "Grafana"), localeIDs: ["pt-BR", "en-US"], vocabulary: [])
        #expect(result.unavailableLocales == [
            .init(localeID: "pt-BR", reason: .noVoice),
            .init(localeID: "en-US", reason: .speechModelNotInstalled)
        ])
        #expect(result.sampleCount == 0)
        #expect(synth.texts.isEmpty)
        #expect(recognizer.vocabularies.isEmpty)
    }

    @Test func exactDiscardedAndFailedSamplesRemainDistinct() async throws {
        let synth = ProbeTestSynthesizer(voices: [voice("en1", "en-US"), voice("en2", "en-US")])
        let recognizer = ProbeTestRecognizer(transcripts: ["I talked about Grafana today.", "wrong carrier"])
        let engine = MishearingProbeEngine(synthesizer: synth, recognizer: recognizer)
        let result = try await engine.probe(term: GlossaryTerm(term: "Grafana"), localeIDs: ["en-US"], vocabulary: [])
        #expect(result.sampleCount == 1)
        #expect(result.exactMatchCount == 1)
        #expect(result.discardedSampleCount == 1)
        #expect(!result.recognizedCorrectly)
        synth.fails = true
        let failed = try await engine.probe(term: GlossaryTerm(term: "Grafana"), localeIDs: ["en-US"], vocabulary: [])
        #expect(failed.failedSampleCount == 2)
        #expect(failed.sampleCount == 0)
    }

    @Test func dropsCarrierSpillAndFlagsEverydayFormsByTheirOwnLocale() async throws {
        // Hypotheses Apple returned for macOS voices on 2026-11-05 (docs/verification/2026-11-05-mishearing-suggestions.md).
        let synth = ProbeTestSynthesizer(voices: [voice("pt1", "pt-BR"), voice("pt2", "pt-BR"), voice("en", "en-US")])
        let recognizer = ProbeTestRecognizer(transcripts: [
            "Eu falei sobre tapecript hoje.", "Eu falei sobre o tipo de crime de hoje.", "I talked about type script today."
        ])
        let checker = ProbeTestWordChecker(everyday: ["en-US": ["type script"], "pt-BR": ["type script"]])
        let result = try await MishearingProbeEngine(synthesizer: synth, recognizer: recognizer, wordChecker: checker)
            .probe(term: GlossaryTerm(term: "TypeScript"), localeIDs: ["pt-BR", "en-US"], vocabulary: [])
        #expect(result.heardForms == ["tapecript", "type script"])
        #expect(result.everydayForms == ["type script"])
        #expect(result.isEveryday("Type Script"))
        #expect(!result.isEveryday("tapecript"))
        #expect(checker.checks == ["tapecript|pt-BR", "type script|en-US"])
    }

    @Test func plausibleFormsNeedTwoLettersAndStayNearTheTermLength() {
        #expect(!MishearingForms.isPlausible("j", longestWordCount: 3))
        #expect(MishearingForms.isPlausible("os rinques", longestWordCount: 3))
        #expect(!MishearingForms.isPlausible("o tipo de crime de", longestWordCount: 3))
        #expect(MishearingForms.suggestions(["j", "postigre SQL"], term: GlossaryTerm(term: "PostgreSQL")) == ["postigre SQL"])
    }

    @Test func canceledEngineDoesNotProceedToRecognition() async {
        let synth = ProbeTestSynthesizer(voices: [voice("en", "en-US")])
        synth.cancels = true
        let recognizer = ProbeTestRecognizer()
        let engine = MishearingProbeEngine(synthesizer: synth, recognizer: recognizer)
        await #expect(throws: CancellationError.self) {
            try await engine.probe(term: GlossaryTerm(term: "Grafana"), localeIDs: ["en-US"], vocabulary: [])
        }
        #expect(recognizer.vocabularies.isEmpty)
    }
}

private func voice(_ id: String, _ locale: String, _ quality: Int = 1) -> MishearingProbeVoice {
    MishearingProbeVoice(id: id, localeID: locale, quality: quality)
}

@MainActor private final class ProbeTestSynthesizer: MishearingSynthesizing {
    let voices: [MishearingProbeVoice]
    var texts: [String] = []
    var fails = false
    var cancels = false
    init(voices: [MishearingProbeVoice]) { self.voices = voices }
    func availableVoices() -> [MishearingProbeVoice] { voices }
    func synthesize(_ text: String, voice: MishearingProbeVoice) async throws -> [AVAudioPCMBuffer] {
        texts.append(text)
        if cancels { throw CancellationError() }
        if fails { throw MishearingProbeFailure.synthesisFailed }
        return []
    }
}

@MainActor private final class ProbeTestWordChecker: MishearingWordChecking {
    let everyday: [String: Set<String>]
    var checks: [String] = []
    init(everyday: [String: Set<String>]) { self.everyday = everyday }
    func isEverydayPhrase(_ phrase: String, localeID: String) -> Bool {
        checks.append("\(phrase)|\(localeID)")
        return everyday[localeID]?.contains(phrase.lowercased()) == true
    }
}

@MainActor private final class ProbeTestRecognizer: MishearingRecognizing {
    var transcripts: [String]
    var unavailable: [String: MishearingProbeUnavailableReason] = [:]
    var vocabularies: [[String]] = []
    init(transcripts: [String] = []) { self.transcripts = transcripts }
    func availability(localeID: String) async -> MishearingProbeUnavailableReason? { unavailable[localeID] }
    func recognize(_ buffers: [AVAudioPCMBuffer], localeID: String, vocabulary: [String]) async throws -> String {
        vocabularies.append(vocabulary)
        return transcripts.removeFirst()
    }
}
