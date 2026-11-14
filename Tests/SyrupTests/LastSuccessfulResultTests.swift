import Foundation
import Testing
@testable import Syrup

@MainActor
struct LastSuccessfulResultTests {
    @Test(arguments: [true, false])
    func lastResultActionsIgnoreAFailedRetryOfAnOlderRevision(paste: Bool) async {
        let suite = testDomainName("FollowUpReview")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        let history = HistoryStore()
        let olderRevision = DictationRecord(
            id: UUID(), finishedAt: Date(timeIntervalSince1970: 1),
            transcript: "shorter", output: "old result",
            transformation: .revision(adjustment: "shorter", instruction: "shorten"),
            outcome: .failed(message: "fixture failure"), provider: .openAICompatible
        )
        history.append(olderRevision)
        history.append(DictationRecord(
            id: UUID(), finishedAt: Date(timeIntervalSince1970: 2),
            transcript: "new dictation", output: "newest successful result",
            transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: .success, provider: .openAICompatible
        ))
        let clipboard = SpyPasteboard()
        let state = AppState.fixture(
            settings: settings, history: history, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("unused")),
            transformer: StaticErrorTextTransformer(error: TranslationError.timedOut),
            pasteboard: clipboard, feedback: SpyFeedback(), autoPaster: SpyAutoPaster(),
            streamingTypistFactory: { SpyStreamingTypist() },
            maximumRecordingDurationNanoseconds: 0, autoPasteDelayNanoseconds: 0,
            frontmostApplication: { _ in ("review.fixture.editor", 1) },
            captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) }
        )
        state.retryTranslation(recordID: olderRevision.id)
        await settle(state)
        #expect(state.pipelineState.isError)
        #expect(clipboard.writes.isEmpty)
        #expect(state.lastResult == "old result")
        if paste { await state.pasteLastResult() } else { state.copyLastResult() }
        #expect(clipboard.writes == ["newest successful result"])

        state.startRevision()
        #expect(state.activeRun?.configuration.purpose == .revision(base: "newest successful result"))
        state.cancelRequested()
    }

    private func settle(_ state: AppState) async {
        await settleRun(state)
    }
}
