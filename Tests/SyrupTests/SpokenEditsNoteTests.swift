import Testing
@testable import Syrup

struct SpokenEditsNoteTests {
    @Test func appleOnDeviceTurnsThemOffAndPointsToACapableProvider() throws {
        let note = try #require(SpokenEditsNote.make(provider: .appleOnDevice, baseURL: "", modelName: ""))
        #expect(note.isAvailable == false)
        #expect(note.tone == .unavailable)
        #expect(note.message == SpokenEditsNote.unavailableCue)
        #expect(note.detail?.contains(SpokenEditsNote.recommendation) == true)
        #expect(note.spokenReason.contains(SpokenEditsNote.unavailableCue))
    }

    @Test(arguments: [
        ("https://api.cerebras.ai/v1", "qwen-3.8-27b"),
        ("https://openrouter.ai/api/v1", "gpt-oss-120b"),
        ("http://localhost:11434/v1", "llama3"),
        ("not a url", ""),
    ])
    func otherOpenAICompatibleModelsGetTheWarning(baseURL: String, modelName: String) throws {
        let note = try #require(SpokenEditsNote.make(provider: .openAICompatible, baseURL: baseURL, modelName: modelName))
        #expect(note.isAvailable)
        #expect(note.tone == .caution)
        #expect(note.message.contains(SpokenEditsNote.recommendation))
    }

    @Test(arguments: [
        ("https://api.cerebras.ai/v1", "gpt-oss-120b"),
        (" https://API.cerebras.ai/v1 ", " GPT-OSS-120B "),
    ])
    func theRecommendedModelIsAcknowledged(baseURL: String, modelName: String) throws {
        let note = try #require(SpokenEditsNote.make(provider: .openAICompatible, baseURL: baseURL, modelName: modelName))
        #expect(note.isAvailable)
        #expect(note.tone == .recommended)
    }

    @Test func codexHasNothingToAdd() {
        #expect(SpokenEditsNote.make(provider: .codexCLI, baseURL: "", modelName: "") == nil)
    }
}
