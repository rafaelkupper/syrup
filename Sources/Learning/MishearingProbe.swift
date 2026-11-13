import AVFoundation
import Foundation

struct MishearingProbeVoice: Equatable, Sendable {
    let id: String
    let localeID: String
    let quality: Int
    /// Novelty voices sing or warp speech, and personal voices belong to a person; neither is a fair speaker.
    var isExcluded = false

    static func select(from voices: [Self], localeID: String) -> [Self] {
        let locale = Locale(identifier: localeID).identifier(.bcp47).lowercased()
        let language = Locale(identifier: localeID).language.languageCode
        var seen: Set<String> = []
        return Array(voices.filter {
            !$0.isExcluded && Locale(identifier: $0.localeID).language.languageCode == language && language != nil
        }.sorted {
            let lhsExact = Locale(identifier: $0.localeID).identifier(.bcp47).lowercased() == locale
            let rhsExact = Locale(identifier: $1.localeID).identifier(.bcp47).lowercased() == locale
            if lhsExact != rhsExact { return lhsExact }
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            // The Siri-era voices (Samantha, Luciana) sound most like a person; Eloquence and older voices follow.
            if $0.isModernSystemVoice != $1.isModernSystemVoice { return $0.isModernSystemVoice }
            return $0.id < $1.id
        }.filter { seen.insert($0.id).inserted }.prefix(2))
    }

    private var isModernSystemVoice: Bool { id.hasPrefix("com.apple.voice.") }
}

struct MishearingCarrier: Sendable {
    let prefix: String
    let suffix: String

    init(localeID: String) {
        switch Locale(identifier: localeID).language.languageCode?.identifier {
        case "pt": (prefix, suffix) = ("Eu falei sobre", "hoje")
        case "en": (prefix, suffix) = ("I talked about", "today")
        default: (prefix, suffix) = ("", "")
        }
    }

    func sentence(term: String) -> String {
        prefix.isEmpty ? term : "\(prefix) \(term) \(suffix)."
    }

    func extract(from transcript: String) -> String? {
        let words = Self.wordRanges(in: transcript)
        let leading = Self.wordRanges(in: prefix).map { String(prefix[$0]) }
        let trailing = Self.wordRanges(in: suffix).map { String(suffix[$0]) }
        guard words.count > leading.count + trailing.count else { return nil }
        func key(_ word: String) -> String {
            word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        guard zip(words.prefix(leading.count), leading).allSatisfy({ key(String(transcript[$0])) == key($1) }),
              zip(words.suffix(trailing.count), trailing).allSatisfy({ key(String(transcript[$0])) == key($1) }) else { return nil }
        let start = leading.isEmpty ? transcript.startIndex : words[leading.count - 1].upperBound
        let end = trailing.isEmpty ? transcript.endIndex : words[words.count - trailing.count].lowerBound
        let value = MishearingForms.cleaned(String(transcript[start..<end]))
        return value.isEmpty ? nil : value
    }

    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while start < text.endIndex,
              let range = text.range(of: #"[\p{L}\p{M}\p{N}]+"#, options: .regularExpression, range: start..<text.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}

enum MishearingForms {
    static func cleaned(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func key(_ text: String) -> String { cleaned(text).lowercased() }

    static func suggestions(_ forms: [String], term: GlossaryTerm) -> [String] {
        var seen = Set(([term.term] + term.mishearings).map(key))
        let longest = wordCount(term.term) + 2
        return Array(forms.map(cleaned).filter {
            isPlausible($0, longestWordCount: longest) && seen.insert(key($0)).inserted
        }.prefix(3))
    }

    /// A form with almost no letters, or one that runs well past the term, is the recognizer
    /// swallowing the carrier sentence ("o tipo de crime de" for TypeScript), not a mishearing.
    static func isPlausible(_ form: String, longestWordCount: Int) -> Bool {
        form.filter(\.isLetter).count >= 2 && wordCount(form) <= longestWordCount
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

/// Whether a heard form is made only of correctly spelled words in its language. Such a hint
/// ("those" for OAuth) can pull a provider into rewriting an ordinary sentence, so the UI warns.
@MainActor
protocol MishearingWordChecking {
    func isEverydayPhrase(_ phrase: String, localeID: String) -> Bool
}

struct NoEverydayWordChecker: MishearingWordChecking {
    func isEverydayPhrase(_ phrase: String, localeID: String) -> Bool { false }
}

enum MishearingProbeUnavailableReason: Equatable, Sendable {
    case noVoice
    case speechModelNotInstalled
    case speechPermissionRequired
    case unsupportedLocale
}

struct MishearingProbeLocaleIssue: Equatable, Sendable {
    let localeID: String
    let reason: MishearingProbeUnavailableReason
}

enum MishearingProbeFailure: Error, Equatable, Sendable {
    case synthesisFailed
    case recognitionFailed
    case timedOut
    case noUsableSamples
}

struct MishearingProbeResult: Equatable, Sendable {
    var heardForms: [String]
    let sampleCount: Int
    let exactMatchCount: Int
    let discardedSampleCount: Int
    let failedSampleCount: Int
    let unavailableLocales: [MishearingProbeLocaleIssue]
    /// The heard forms made only of everyday words in the language that produced them.
    var everydayForms: [String] = []

    func isEveryday(_ form: String) -> Bool {
        everydayForms.contains { MishearingForms.key($0) == MishearingForms.key(form) }
    }

    var recognizedCorrectly: Bool {
        sampleCount > 0 && exactMatchCount == sampleCount && discardedSampleCount == 0
            && failedSampleCount == 0 && unavailableLocales.isEmpty
    }
}

@MainActor
protocol MishearingSynthesizing {
    func availableVoices() -> [MishearingProbeVoice]
    func synthesize(_ text: String, voice: MishearingProbeVoice) async throws -> [AVAudioPCMBuffer]
}

@MainActor
protocol MishearingRecognizing {
    func availability(localeID: String) async -> MishearingProbeUnavailableReason?
    func recognize(_ buffers: [AVAudioPCMBuffer], localeID: String, vocabulary: [String]) async throws -> String
}

@MainActor
protocol MishearingProbing {
    func probe(term: GlossaryTerm, localeIDs: [String], vocabulary: [String]) async throws -> MishearingProbeResult
}

@MainActor
final class MishearingProbeEngine: MishearingProbing {
    private let synthesizer: any MishearingSynthesizing
    private let recognizer: any MishearingRecognizing
    private let wordChecker: any MishearingWordChecking

    init(synthesizer: any MishearingSynthesizing, recognizer: any MishearingRecognizing,
         wordChecker: any MishearingWordChecking = NoEverydayWordChecker()) {
        self.synthesizer = synthesizer
        self.recognizer = recognizer
        self.wordChecker = wordChecker
    }

    func probe(term: GlossaryTerm, localeIDs: [String], vocabulary: [String]) async throws -> MishearingProbeResult {
        var forms: [String] = []
        var formLocales: [String: String] = [:]
        var samples = 0
        var exact = 0
        var discarded = 0
        var failed = 0
        var unavailable: [MishearingProbeLocaleIssue] = []
        let voices = synthesizer.availableVoices()
        for localeID in localeIDs {
            try Task.checkCancellation()
            let selected = MishearingProbeVoice.select(from: voices, localeID: localeID)
            guard !selected.isEmpty else {
                unavailable.append(.init(localeID: localeID, reason: .noVoice))
                continue
            }
            if let reason = await recognizer.availability(localeID: localeID) {
                unavailable.append(.init(localeID: localeID, reason: reason))
                continue
            }
            let carrier = MishearingCarrier(localeID: localeID)
            for voice in selected {
                try Task.checkCancellation()
                do {
                    let buffers = try await synthesizer.synthesize(carrier.sentence(term: term.term), voice: voice)
                    try Task.checkCancellation()
                    let transcript = try await recognizer.recognize(buffers, localeID: localeID, vocabulary: vocabulary)
                    try Task.checkCancellation()
                    guard let heard = carrier.extract(from: transcript) else { discarded += 1; continue }
                    samples += 1
                    if MishearingForms.key(heard) == MishearingForms.key(term.term) { exact += 1 }
                    forms.append(heard)
                    if formLocales[MishearingForms.key(heard)] == nil { formLocales[MishearingForms.key(heard)] = localeID }
                } catch is CancellationError { throw CancellationError() }
                catch { failed += 1 }
            }
        }
        try Task.checkCancellation()
        let suggestions = MishearingForms.suggestions(forms, term: term)
        return MishearingProbeResult(
            heardForms: suggestions, sampleCount: samples,
            exactMatchCount: exact, discardedSampleCount: discarded, failedSampleCount: failed,
            unavailableLocales: unavailable,
            everydayForms: suggestions.filter { form in
                formLocales[MishearingForms.key(form)].map { wordChecker.isEverydayPhrase(form, localeID: $0) } ?? false
            }
        )
    }
}
