import Foundation
import Testing
@testable import Syrup

struct MishearingJudgeTests {
    @Test(arguments: [
        #"{"findings":[{"term":"Kubernetes","mishearings":["cuber netties"],"confidence":0.9}]}"#,
        """
        ```
        {"findings":[{"term":"Kubernetes","mishearings":["cuber netties"],"confidence":0.9}]}
        ```
        """,
        """
        ```json
        {"findings":[{"term":"Kubernetes","mishearings":["cuber netties"],"confidence":0.9}]}
        ```
        """,
        "Here is the result: {\"findings\":[{\"term\":\"Kubernetes\",\"mishearings\":[\"cuber netties\"],\"confidence\":0.9}]} Thanks.",
    ])
    func parserAcceptsSupportedResponseShapes(_ response: String) throws {
        let finding = try #require(LLMMishearingJudge.parseFindings(from: response)?.first)

        #expect(finding == JudgeFinding(
            term: "Kubernetes",
            mishearings: ["cuber netties"],
            confidence: 0.9
        ))
    }

    /// The term must be in transcript B and each mishearing in transcript A, as whole words.
    @Test
    func onlyFindingsBothTranscriptsSupportAreKept() {
        let pair = TranscriptPair(
            recordingID: UUID(), localeID: "pt-BR",
            appleTranscript: "Rodei o cuber netties, e o rapid deu certo.",
            whisperTranscript: "Rodei o Kubernetes e o rapid deu certo."
        )
        let findings = [
            JudgeFinding(term: "Kubernetes", mishearings: ["cuber netties", "invented"], confidence: 0.9),
            JudgeFinding(term: "Invented", mishearings: ["cuber netties"], confidence: 0.9),
            JudgeFinding(term: "API", mishearings: ["rapid"], confidence: 0.9),
            JudgeFinding(term: "rapid", mishearings: ["api"], confidence: 0.9),
        ]
        #expect(LLMMishearingJudge.verified(findings, against: pair) == [
            JudgeFinding(term: "Kubernetes", mishearings: ["cuber netties"], confidence: 0.9),
        ])
    }

    @Test
    func aFloodOfFindingsIsCapped() {
        let words = (1...12).map { "word\($0)" }
        let pair = TranscriptPair(
            recordingID: UUID(), localeID: "en-US",
            appleTranscript: words.joined(separator: " "), whisperTranscript: words.joined(separator: " ")
        )
        let findings = words.map { JudgeFinding(term: $0, mishearings: words, confidence: 0.9) }
            + [JudgeFinding(term: String(repeating: "x", count: 61), mishearings: ["word1"], confidence: 0.9)]
        let kept = LLMMishearingJudge.verified(findings, against: pair)
        #expect(kept.count == LLMMishearingJudge.maximumFindingsPerPair)
        #expect(kept.allSatisfy { $0.mishearings.count == LLMMishearingJudge.maximumMishearingsPerFinding })
    }

    @Test
    func storedProposalsAndDismissalsAreCapped() {
        var list = GlossaryProposalList()
        for index in 0...GlossaryProposalList.maximumProposals {
            list.addIfNew(GlossaryProposal(id: UUID(), term: "Term\(index)", mishearings: ["t"], confidence: 0.9, createdAt: .now),
                          existingGlossary: GlossaryList())
        }
        #expect(list.proposals.count == GlossaryProposalList.maximumProposals)
        for _ in 0...GlossaryProposalList.maximumDismissedKeys {
            let proposal = GlossaryProposal(id: UUID(), term: UUID().uuidString, mishearings: ["t"], confidence: 0.9, createdAt: .now)
            list.proposals = [proposal]
            list.dismiss(id: proposal.id)
        }
        #expect(list.dismissedKeys.count == GlossaryProposalList.maximumDismissedKeys)
    }

    @Test
    func parserDistinguishesGarbageFromAnEmptyFindingSet() {
        #expect(LLMMishearingJudge.parseFindings(from: "not JSON") == nil)
        #expect(LLMMishearingJudge.parseFindings(from: #"{"findings":[]}"#) == [])
    }

    @Test
    func parserAppliesConfidenceAndMishearingValidityFilters() throws {
        let response = #"{"findings":[{"term":"Below","mishearings":["bellow"],"confidence":0.59},{"term":"Kept","mishearings":[" kept ","capt"],"confidence":0.6},{"term":"Same","mishearings":["SAME"],"confidence":0.9},{"term":"  ","mishearings":["word"],"confidence":0.9}]}"#

        let findings = try #require(LLMMishearingJudge.parseFindings(from: response))

        #expect(findings == [JudgeFinding(term: "Kept", mishearings: ["capt"], confidence: 0.6)])
    }

    @Test
    @MainActor
    func judgeUsesConfiguredProviderAndSendsOnlyTheTranscriptPair() async throws {
        let transformer = JudgeFakeTransformer(
            output: #"{"findings":[{"term":"Syrup","mishearings":["sirup"],"confidence":0.8}]}"#
        )
        let provider = JudgeFakeTransformerProvider(transformer: transformer)
        let judge = LLMMishearingJudge(
            transformerProvider: provider,
            providerReader: { .codexCLI }
        )
        let pair = TranscriptPair(
            recordingID: UUID(),
            localeID: "pt-BR",
            appleTranscript: "use sirup",
            whisperTranscript: "use Syrup"
        )

        let findings = await judge.findings(for: pair)
        let providerCall = try #require(await provider.call)
        let transformCall = try #require(await transformer.call)

        #expect(providerCall.provider == .codexCLI)
        #expect(providerCall.instruction == LLMMishearingJudge.instruction)
        #expect(transformCall.instruction == LLMMishearingJudge.instruction)
        #expect(transformCall.text == "A: use sirup\nB: use Syrup")
        #expect(transformCall.instruction.contains("EXCLUDE") == false)
        #expect(findings == [JudgeFinding(term: "Syrup", mishearings: ["sirup"], confidence: 0.8)])
    }
}

private actor JudgeFakeTransformer: TextTransformer {
    struct Call: Sendable {
        let text: String
        let instruction: String
    }

    let output: String
    private(set) var call: Call?

    init(output: String) {
        self.output = output
    }

    func transform(_ text: String, instruction: String) async throws -> String {
        call = Call(text: text, instruction: instruction)
        return output
    }
}

private actor JudgeFakeTransformerProvider: TransformerSource {
    struct Call: Sendable {
        let provider: TranslationProvider
        let instruction: String
    }

    let transformer: any TextTransformer
    private(set) var call: Call?

    init(transformer: any TextTransformer) {
        self.transformer = transformer
    }

    func transformer(
        for provider: TranslationProvider,
        instruction: String
    ) async -> any TextTransformer {
        call = Call(provider: provider, instruction: instruction)
        return transformer
    }
}
