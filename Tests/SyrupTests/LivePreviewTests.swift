import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// The recording cue output preview and recognition preferences.
@MainActor
struct LivePreviewTests {
    @Test func passivePreviewStreamsWithoutPastingAndCancelPreservesClipboard() async {
        let settings = fixtureSettings()
        settings.showRecordingCue = true
        settings.autoPasteEnabled = false
        settings.streamingDeliveryEnabled = false
        let cue = OutputPreviewSpy()
        let pasteboard = SpyPasteboard()
        let paster = SpyAutoPaster(isTrusted: false)
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        defer { continuation.finish() }
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("fixture")),
            transformer: FakeStreamingTextTransformer(stream: stream), pasteboard: pasteboard,
            feedback: SpyFeedback(), autoPaster: paster, maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
            recordingCue: cue)
        state.triggerPressed()
        state.triggerReleased()
        continuation.yield("Visible partial")
        await eventually { cue.outputs.isEmpty == false }
        #expect(cue.outputs == ["Visible partial"])
        #expect(pasteboard.writes.isEmpty)
        #expect(paster.pasteCount == 0)
        state.cancelRequested()
        continuation.yield(" stale")
        continuation.finish()
        await state.waitForPendingWork()
        #expect(state.pipelineState == .idle)
        #expect(pasteboard.writes.isEmpty)
        #expect(cue.outputs == ["Visible partial"])
    }

    @Test func previewAndFastRecognitionPreferencesAreIndependent() {
        let settings = fixtureSettings()
        settings.showLiveTranscript = true
        #expect(settings.preferFastTranscription == false)
        settings.preferFastTranscription = true
        settings.showLiveTranscript = false
        #expect(settings.preferFastTranscription)
        #expect(settings.pinDeliveryTarget)
    }

    private func fixtureSettings() -> AppSettings {
        let defaults = TestDefaults(suiteName: testDomainName("SyrupReviewTests"))!
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.showRecordingCue = false
        settings.playSounds = false
        return settings
    }
}

@MainActor private final class OutputPreviewSpy: RecordingCuePresenting {
    private(set) var outputs: [String] = []
    func apply(_ state: RecordingCueState) {}
    func updateLevel(_ level: Double) {}
    func updateTranscript(_ text: String) {}
    func updateOutput(_ text: String) -> Bool { outputs.append(text); return true }
}
