import Foundation
import Testing
@testable import Syrup

@MainActor
struct SpeechEngineTests {
    @Test(arguments: ["pt-BR", "pt_BR", "pt-PT", "en-US", "uk-UA", "bg-BG", "mt-MT"])
    func parakeetSupportsTheModelCardLanguages(localeID: String) {
        #expect(SpeechEngine.parakeetUltra.supports(localeID: localeID))
        #expect(SpeechEngine.parakeetRedux.supports(localeID: localeID))
    }

    @Test(arguments: ["ja-JP", "zh-CN", "ko-KR", "ar-SA", "sr-RS", "bs-BA", "be-BY"])
    func parakeetRejectsOtherLanguagesAndAppleTakesThem(localeID: String) {
        #expect(SpeechEngine.parakeetUltra.supports(localeID: localeID) == false)
        #expect(SpeechEngine.parakeetRedux.supports(localeID: localeID) == false)
        #expect(SpeechEngine.apple.supports(localeID: localeID))
    }

    @Test func workflowsThatChoseParakeetV3NowUseUltra() throws {
        let blob = Data(
            #"{"version":3,"workflows":[{"id":"00000000-0000-0000-0000-000000000001","name":"Ditado","kind":{"transcribeOnly":{"cleanup":true}},"dictationLocaleID":"pt-BR","translationProvider":null,"speechEngine":"parakeet_v3"}],"activeWorkflowID":"00000000-0000-0000-0000-000000000001"}"#.utf8
        )
        let list = try JSONDecoder().decode(WorkflowList.self, from: blob)
        #expect(list.workflows.map(\.speechEngine) == [.parakeetUltra])
        let saved = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
        #expect(saved.contains(#""speechEngine":"parakeet_ultra""#))
    }

    @Test func workflowsSavedBeforeEngineChoiceDecodeAsApple() throws {
        let blob = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","kind":{"custom":{"instruction":"Polish this.","enforceOutputContract":true}},"dictationLocaleID":"pt-BR","translationProvider":null}"#.utf8
        )
        #expect(try JSONDecoder().decode(Workflow.self, from: blob).speechEngine == .apple)
    }

    @Test func anUnknownEngineDecodesAsAppleWithoutLosingTheList() throws {
        let blob = Data(
            #"{"version":3,"workflows":[{"id":"00000000-0000-0000-0000-000000000001","name":"Future","kind":{"transcribeOnly":{"cleanup":true}},"dictationLocaleID":"pt-BR","translationProvider":null,"speechEngine":"future_engine"}],"activeWorkflowID":"00000000-0000-0000-0000-000000000001"}"#.utf8
        )
        let list = try JSONDecoder().decode(WorkflowList.self, from: blob)
        #expect(list.workflows.map(\.name) == ["Future"])
        #expect(list.workflows.map(\.speechEngine) == [.apple])
    }

    @Test func parakeetPersistsAndUnsupportedLanguagesKeepApple() throws {
        let portuguese = workflow(locale: "pt-BR", engine: .parakeetUltra)
        #expect(try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(portuguese)).speechEngine == .parakeetUltra)
        #expect(workflow(locale: "ja-JP", engine: .parakeetUltra).speechEngine == .apple)

        var list = WorkflowList(workflows: [portuguese])
        list.updateWorkflow(id: portuguese.id) { $0.dictationLocaleID = "ja-JP" }
        #expect(list.activeWorkflow.speechEngine == .apple)
        list.updateWorkflow(id: portuguese.id) { $0.speechEngine = .parakeetUltra }
        #expect(list.activeWorkflow.speechEngine == .apple)
    }

    @Test func runsAndDuplicatesCarryTheWorkflowEngine() throws {
        let suite = "SpeechEngineTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        let id = settings.activeWorkflow.id

        #expect(settings.runConfiguration(workflowID: id).speechEngine == .apple)
        settings.updateWorkflow(id: id) { $0.speechEngine = .parakeetUltra }
        #expect(settings.runConfiguration(workflowID: id).speechEngine == .parakeetUltra)
        let duplicateID = try #require(settings.duplicateWorkflow(id: id))
        #expect(settings.runConfiguration(workflowID: duplicateID).speechEngine == .parakeetUltra)
    }

    private func workflow(locale: String, engine: SpeechEngine) -> Workflow {
        Workflow(id: UUID(), name: locale, kind: .transcribeOnly(cleanup: true), dictationLocaleID: locale,
                 translationProvider: nil, speechEngine: engine)
    }
}
