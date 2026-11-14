import AVFoundation
import Foundation
import Testing
@testable import Syrup

@MainActor
struct PipelineLifecycleRegressionTests {
    private func settings() -> (AppSettings, String) {
        let name = testDomainName("SyrupReview")
        let settings = AppSettings(userDefaults: TestDefaults(suiteName: name)!, defaultMicrophoneIDProvider: { "" })
        settings.showRecordingCue = false
        settings.playSounds = false
        return (settings, name)
    }

    @Test func cancellationDuringPermissionMustNotLeaveCaptureRunning() async throws {
        let (settings, name) = settings()
        defer { TestDefaults.removeSuite(name) }
        let permission = ReviewPermissionGate()
        let capture = ReviewCapture()
        let realRecorder = AudioRecorder(settings: settings, deviceCatalog: ReviewDeviceCatalog(), microphonePermissionRequester: {
            await permission.wait()
        }, captureSessionFactory: { _, _ in capture })
        let recorder = StartObservingRecorder(realRecorder)
        let state = AppState.fixture(settings: settings, audioRecorder: recorder,
            transcriber: FakeTranscriber(.success("fixture")), transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
        state.triggerPressed()
        await eventually("The permission request never started") { permission.continuation != nil }
        state.cancelRequested()
        permission.continuation?.resume(returning: true)
        permission.continuation = nil
        await eventually("The recorder never returned after permission") { recorder.startReturned }
        #expect(state.pipelineState == .idle)
        #expect(capture.isRunning == false, "Cancelled run started microphone capture after permission returned")
        realRecorder.stop()
    }

    @Test func earlyRecognitionFailureMustStopRecordingWithoutRelease() async throws {
        let (settings, name) = settings()
        defer { TestDefaults.removeSuite(name) }
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(.failure(.speechPermission))
        let state = AppState.fixture(settings: settings, audioRecorder: recorder,
            transcriber: transcriber, transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
        state.triggerPressed()
        await transcriber.waitForCall()
        await eventually("Known speech failure is hidden until the user stops recording") {
            state.pipelineState != .recording
        }
        #expect(recorder.stopCallCount > 0)
        state.cancelRequested()
    }
}

@MainActor private final class ReviewPermissionGate {
    var continuation: CheckedContinuation<Bool, Never>?
    func wait() async -> Bool { await withCheckedContinuation { continuation = $0 } }
}
private final class ReviewCapture: AudioCaptureSessioning, @unchecked Sendable {
    var isRunning = false
    func start(selectedDeviceUID: String?) throws { isRunning = true }
    func stop() { isRunning = false }
}
private struct ReviewDeviceCatalog: AudioInputDeviceCataloging {
    func inputDevices() -> [AudioInputDevice] { [] }
    func inputDevice(for uid: String) -> AudioInputDevice? { nil }
    func defaultInputDevice() -> AudioInputDevice? { nil }
}
/// Forwards to a real recorder and reports when `start()` has returned or thrown.
@MainActor private final class StartObservingRecorder: AudioRecording {
    private let recorder: AudioRecorder
    private(set) var startReturned = false
    var onFailure: (@MainActor (any Error) -> Void)? {
        get { recorder.onFailure }
        set { recorder.onFailure = newValue }
    }

    init(_ recorder: AudioRecorder) { self.recorder = recorder }

    func start() async throws -> AudioBufferSequence {
        defer { startReturned = true }
        return try await recorder.start()
    }

    func stop() { recorder.stop() }
    func finish() async throws { try await recorder.finish() }
}
