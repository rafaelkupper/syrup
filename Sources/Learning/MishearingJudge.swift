import Foundation
import OSLog

protocol MishearingJudging: Sendable {
    /// nil = judge unavailable/failed (retry later); [] = judged, nothing found.
    /// Only the transcript pair leaves the Mac; glossary terms are filtered locally by the caller.
    func findings(for pair: TranscriptPair) async -> [JudgeFinding]?
}

struct JudgeFinding: Equatable, Sendable, Codable {
    let term: String
    let mishearings: [String]
    let confidence: Double
}

struct LLMMishearingJudge: MishearingJudging {
    static let instruction = """
    You compare two transcripts of the same spoken audio. Transcript A is from
    a locale-locked recognizer that often mangles words spoken in a different
    language (usually English terms embedded in another language). Transcript B
    is from a multilingual recognizer that handles such embedded terms better
    but sometimes hallucinates. Identify terms where B is plausibly correct and
    A misheard — focus on product names, technical vocabulary, proper nouns,
    and cross-language terms. Ignore punctuation, casing, fillers, and ordinary
    same-language word differences. Reply with ONLY this JSON, no other text:
    {"findings":[{"term":"<correct spelling from B>","mishearings":["<A's version>"],"confidence":<0.0-1.0>}]}
    Reply {"findings":[]} if there are none.
    """

    private let transformerProvider: any TransformerSnapshotting
    private let providerReader: @MainActor @Sendable () -> TranslationProvider
    private static let logger = Logger(
        subsystem: "org.syrup.SyrupApp",
        category: "GlossaryLearning"
    )

    init(
        transformerProvider: any TransformerSnapshotting,
        providerReader: @escaping @MainActor @Sendable () -> TranslationProvider
    ) {
        self.transformerProvider = transformerProvider
        self.providerReader = providerReader
    }

    func findings(for pair: TranscriptPair) async -> [JudgeFinding]? {
        let instruction = Self.instruction
        let body = """
        A: \(pair.appleTranscript)
        B: \(pair.whisperTranscript)
        """
        let provider = await providerReader()
        let snapshot = await transformerProvider.snapshot(for: provider)
        let transformer = await snapshot.transformer(instruction: instruction)

        do {
            let response = try await transformer.transform(body, instruction: instruction)
            return Self.parseFindings(from: response).map { Self.verified($0, against: pair) }
        } catch {
            Self.logger.error("mishearing_judge_failed")
            return nil
        }
    }

    static func parseFindings(from raw: String) -> [JudgeFinding]? {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = candidate.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count >= 2,
           isOpeningFence(String(lines[0])),
           lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            candidate = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let firstBrace = candidate.firstIndex(of: "{"),
              let lastBrace = candidate.lastIndex(of: "}"),
              firstBrace <= lastBrace else {
            return nil
        }

        let data = Data(candidate[firstBrace...lastBrace].utf8)
        guard let response = try? JSONDecoder().decode(JudgeResponse.self, from: data) else {
            return nil
        }

        return response.findings.compactMap { finding in
            let term = finding.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard finding.confidence >= 0.6, term.isEmpty == false else { return nil }

            let termKey = term.lowercased()
            let mishearings = finding.mishearings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false && $0.lowercased() != termKey }
            guard mishearings.isEmpty == false else { return nil }

            return JudgeFinding(
                term: term,
                mishearings: mishearings,
                confidence: finding.confidence
            )
        }
    }

    /// One dictation has a handful of terms; a reply with more findings is a judge gone wrong.
    static let maximumFindingsPerPair = 5
    static let maximumMishearingsPerFinding = 3
    /// Anything longer is a phrase, not vocabulary.
    static let maximumTermCharacters = 60

    /// Keeps only what the two transcripts support: the term must appear in transcript B and each
    /// mishearing in transcript A, as whole words, ignoring case and punctuation. A judge that invents
    /// either, or floods the reply, adds nothing, and the counts and lengths are capped.
    static func verified(_ findings: [JudgeFinding], against pair: TranscriptPair) -> [JudgeFinding] {
        let heard = wordText(pair.appleTranscript)
        let recognized = wordText(pair.whisperTranscript)
        func appears(_ phrase: String, in text: String) -> Bool {
            let words = wordText(phrase)
            return words.trimmingCharacters(in: .whitespaces).isEmpty == false
                && phrase.count <= maximumTermCharacters && text.contains(words)
        }
        let supported = findings.compactMap { finding -> JudgeFinding? in
            guard appears(finding.term, in: recognized) else { return nil }
            let mishearings = finding.mishearings.filter { appears($0, in: heard) }.prefix(maximumMishearingsPerFinding)
            guard mishearings.isEmpty == false else { return nil }
            return JudgeFinding(term: finding.term, mishearings: Array(mishearings), confidence: finding.confidence)
        }
        return Array(supported.prefix(maximumFindingsPerPair))
    }

    /// Lowercased words separated by single spaces, with a space at each end so whole words match.
    private static func wordText(_ text: String) -> String {
        let words = text.lowercased().unicodeScalars
            .map { CharacterSet.punctuationCharacters.union(.symbols).contains($0) ? " " : Character($0) }
        return " " + String(words).split(whereSeparator: \.isWhitespace).joined(separator: " ") + " "
    }

    private static func isOpeningFence(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "```" || normalized == "```json"
    }

    private struct JudgeResponse: Decodable {
        let findings: [JudgeFinding]
    }
}
