import Foundation
import OSLog

protocol MishearingJudging: Sendable {
    /// nil = judge unavailable/failed (retry later); [] = judged, nothing found.
    func findings(
        for pair: TranscriptPair,
        excluding terms: [String]
    ) async -> [JudgeFinding]?
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
    Reply {"findings":[]} if there are none. Do not include terms from the
    EXCLUDE list.
    """

    private let transformerProvider: any TransformerProviding
    private let providerReader: @MainActor @Sendable () -> TranslationProvider
    private static let logger = Logger(
        subsystem: "org.syrup.SyrupApp",
        category: "GlossaryLearning"
    )

    init(
        transformerProvider: any TransformerProviding,
        providerReader: @escaping @MainActor @Sendable () -> TranslationProvider
    ) {
        self.transformerProvider = transformerProvider
        self.providerReader = providerReader
    }

    func findings(
        for pair: TranscriptPair,
        excluding terms: [String]
    ) async -> [JudgeFinding]? {
        let instruction = Self.instruction
        let body = """
        EXCLUDE: \(terms.joined(separator: ", "))
        A: \(pair.appleTranscript)
        B: \(pair.whisperTranscript)
        """
        let provider = await providerReader()
        let transformer = await transformerProvider.transformer(
            for: provider,
            instruction: instruction
        )

        do {
            let response = try await transformer.transform(body, instruction: instruction)
            return Self.parseFindings(from: response)
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

    private static func isOpeningFence(_ line: String) -> Bool {
        let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "```" || normalized == "```json"
    }

    private struct JudgeResponse: Decodable {
        let findings: [JudgeFinding]
    }
}
