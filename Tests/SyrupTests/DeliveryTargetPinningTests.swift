import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// A pinned editor that loses focus falls back to the clipboard.
@MainActor
struct DeliveryTargetPinningTests {
    @Test func switchingAppsDuringTheFocusReadFailsTheCheck() async {
        var frontmost: pid_t? = 42
        let switched = await DeliveryTarget.focusStillHeld(
            by: 42, frontmost: { frontmost },
            focusMatches: { await MainActor.run { frontmost = 7 }; return true }
        )
        #expect(switched == false)

        frontmost = 42
        #expect(await DeliveryTarget.focusStillHeld(by: 42, frontmost: { frontmost }, focusMatches: { true }))
        #expect(await DeliveryTarget.focusStillHeld(by: 42, frontmost: { frontmost }, focusMatches: { false }) == false)
        frontmost = 7
        #expect(await DeliveryTarget.focusStillHeld(by: 42, frontmost: { frontmost }, focusMatches: { true }) == false)
    }

    @Test func editorChangeDuringPasteDelayFallsBackToClipboard() async {
        let settings = fixtureSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = false
        let pasteboard = SpyPasteboard()
        let paster = SpyAutoPaster()
        var sameEditor = true
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("input")), transformer: FakeTextTransformer(.success("output")),
            pasteboard: pasteboard, feedback: SpyFeedback(), autoPaster: paster,
            maximumRecordingDurationNanoseconds: 0,
            autoPasteSleeper: { _ in await MainActor.run { sameEditor = false } }, recordingClock: FastForwardClock(),
            captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { sameEditor }) })
        state.triggerPressed()
        state.triggerReleased()
        await eventually { state.pipelineState == .idle }
        #expect(state.pipelineState == .idle)
        #expect(pasteboard.writes == ["output"])
        #expect(paster.pasteCount == 0)
    }

    @Test func sameApplicationFieldChangeStopsStreaming() async throws {
        let editor = EditorFocus()
        var posted: [TypingStep] = []
        let typist = StreamingTypist(sizeThreshold: 1, trustStatus: { true }, secureInputStatus: { false },
            frontmostApplicationID: { "fixture.editor" }, eventPoster: { posted.append($0); return true })
        typist.setTargetValidator { editor.isSame }
        try typist.start()
        typist.append("first ")
        await typist.waitForQueuedFlushes()
        let beforeFocusChange = posted
        #expect(beforeFocusChange.isEmpty == false)
        editor.isSame = false
        typist.append("second")
        await typist.waitForQueuedFlushes()
        await typist.finish()
        #expect(posted == beforeFocusChange)
        #expect(typist.stopReason == .focusChanged)
    }

    private func fixtureSettings() -> AppSettings {
        let defaults = TestDefaults(suiteName: testDomainName("SyrupReviewTests"))!
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.showRecordingCue = false
        settings.playSounds = false
        return settings
    }
}

@MainActor
private final class EditorFocus {
    var isSame = true
}
