import Foundation
import Testing
@testable import Syrup

@MainActor
struct TextSafetyRegressionTests {
    @Test(arguments: [
        ("pt-BR", "Tenho dois pontos para discutir"),
        ("pt-BR", "Comprei uma barra de chocolate"),
        ("en-US", "I want to underscore the risk"),
        ("en-US", "Use the event hashtag on every post"),
    ])
    func defaultTranscribeKeepsOrdinaryWords(locale: String, spoken: String) async {
        let suite = "ReviewRepro.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        let template = WorkflowTemplate.templates().first { $0.id == "transcribe" }!
        let id = settings.addWorkflow(from: template)
        settings.updateWorkflow(id: id) { $0.dictationLocaleID = locale }
        let clipboard = SpyPasteboard()
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(),
                             transcriber: FakeTranscriber(.success(spoken)),
                             transformer: QueuedTextTransformer([]),
                             pasteboard: clipboard, feedback: SpyFeedback(),
                             maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline, state.pipelineState != .idle, !state.pipelineState.isError {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(clipboard.writes == [spoken])
    }

}

struct SpokenSymbolSettingsTests {
    @Test(arguments: [1, 2, 3])
    func oldWorkflowListsDecodeSymbolsOff(version: Int) throws {
        let json = """
        {"version":\(version),"workflows":[{"id":"00000000-0000-0000-0000-000000000001","name":"Local","kind":{"transcribeOnly":{"cleanup":true}},"dictationLocaleID":"en-US"}],"activeWorkflowID":"00000000-0000-0000-0000-000000000001"}
        """
        let list = try JSONDecoder().decode(WorkflowList.self, from: Data(json.utf8))
        #expect(list.activeWorkflow.kind == .transcribeOnly(cleanup: true, spokenSymbols: false))
    }

    @Test(arguments: [true, false])
    func symbolsRoundTripIndependentlyOfCleanup(cleanup: Bool) throws {
        let kind = WorkflowKind.transcribeOnly(cleanup: cleanup, spokenSymbols: true)
        #expect(try JSONDecoder().decode(WorkflowKind.self, from: JSONEncoder().encode(kind)) == kind)
        #expect(TranscriptCleanup.apply("name underscore value", localeID: "en-US", cleanup: cleanup, spokenSymbols: true) == "name_value")
    }
}
