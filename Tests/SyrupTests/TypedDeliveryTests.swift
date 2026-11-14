import Foundation
import Testing
@testable import Syrup

@MainActor
struct TypedDeliveryTests {
    @Test(arguments: [["result", " more"], ["x"], [String(repeating: "word ", count: 50), "end"]])
    func streamingSmartSpacingSurvivesTheRealTypist(deltas: [String]) async {
        let suite = testDomainName("FollowUpReview")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        settings.smartSpacingEnabled = true
        let clipboard = SpyPasteboard()
        var posted: [TypingStep] = []
        let typist = StreamingTypist(
            trustStatus: { true }, secureInputStatus: { false },
            frontmostApplicationID: { "review.fixture.editor" },
            eventPoster: { posted.append($0); return true }
        )
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("hello")),
            transformer: FakeStreamingTextTransformer(deltas: deltas),
            pasteboard: clipboard, feedback: SpyFeedback(), autoPaster: SpyAutoPaster(),
            streamingTypistFactory: { typist }, maximumRecordingDurationNanoseconds: 0,
            autoPasteDelayNanoseconds: 0, recordingClock: FastForwardClock(),
            frontmostApplication: { _ in ("review.fixture.editor", 1) },
            captureDeliveryTarget: { _ in
                DeliveryTarget(checkCurrent: { true }, spacingProbe: { true })
            }
        )
        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await settle(state)
        let delivered = posted.map { step in
            switch step { case .text(let text): text; case .lineBreak: "\n" }
        }.joined()
        #expect(clipboard.writes == [deltas.joined()])
        #expect(delivered == " " + deltas.joined())
    }

    @Test(arguments: [(ownProcess: true, expectedPastes: 0), (ownProcess: false, expectedPastes: 1)])
    func onboardingHoldsPasteOnlyWhileSyrupIsInFront(ownProcess: Bool, expectedPastes: Int) async {
        let suite = testDomainName("FollowUpReview")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.autoPasteEnabled = true
        let clipboard = SpyPasteboard()
        let paster = SpyAutoPaster()
        let processID = ownProcess ? ProcessInfo.processInfo.processIdentifier : 1
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("hello")),
            transformer: FakeTextTransformer(.success("olá")),
            pasteboard: clipboard, feedback: SpyFeedback(), autoPaster: paster,
            maximumRecordingDurationNanoseconds: 0,
            autoPasteDelayNanoseconds: 0, recordingClock: FastForwardClock(),
            frontmostApplication: { _ in ("review.fixture.editor", processID) },
            captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) }
        )
        state.holdsPasteForOnboarding = true
        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await settle(state)
        #expect(clipboard.writes == ["olá"])
        #expect(paster.pasteCount == expectedPastes)
    }

    @Test func repeatedSpacingRequestPostsOnlyOneSpace() async throws {
        var posted = ""
        let typist = StreamingTypist(trustStatus: { true }, secureInputStatus: { false },
                                    frontmostApplicationID: { "fixture" }, eventPoster: {
            if case .text(let text) = $0 { posted += text }
            return true
        })
        try typist.start()
        typist.addLeadingSpace()
        typist.addLeadingSpace()
        typist.append("  \"word\"  ")
        await typist.waitForQueuedFlushes()
        await typist.finish()
        #expect(posted == " word")
    }

    private func settle(_ state: AppState) async {
        await settleRun(state)
    }
}
