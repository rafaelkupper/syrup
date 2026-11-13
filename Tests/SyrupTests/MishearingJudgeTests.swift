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
    func judgeUsesConfiguredProviderAndSendsExactContractWithExcludeList() async throws {
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

        let findings = await judge.findings(for: pair, excluding: ["Kubernetes", "Codex"])
        let providerCall = try #require(await provider.call)
        let transformCall = try #require(await transformer.call)

        #expect(providerCall.provider == .codexCLI)
        #expect(providerCall.instruction == LLMMishearingJudge.instruction)
        #expect(transformCall.instruction == LLMMishearingJudge.instruction)
        #expect(transformCall.text == "EXCLUDE: Kubernetes, Codex\nA: use sirup\nB: use Syrup")
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

private actor JudgeFakeTransformerProvider: TransformerProviding {
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
