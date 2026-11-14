import AVFoundation
import Foundation
import Testing
@testable import Syrup

@MainActor
struct PipelineLifecycleRegressionTests {
    private func settings(learning: Bool = false) -> (AppSettings, String) {
        let name = testDomainName("SyrupReview")
        let settings = AppSettings(userDefaults: TestDefaults(suiteName: name)!, defaultMicrophoneIDProvider: { "" })
        settings.privacyOptIns.setGlossaryLearning(learning)
        settings.showRecordingCue = false
        settings.playSounds = false
        return (settings, name)
    }

    @Test func listingPendingMustPreserveActiveWAV() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupReviewArchive"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let url = try await archive.beginEntry(id: UUID())
        #expect(FileManager.default.fileExists(atPath: url.path))
        _ = await archive.pendingEntries()
        #expect(FileManager.default.fileExists(atPath: url.path), "Listing pending entries deleted an active WAV")
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

    @Test func oldFailureCleanupMustNotOverwriteNewRun() async throws {
        let (settings, name) = settings(learning: true)
        defer { TestDefaults.removeSuite(name) }
        let archive = ReviewCleanupArchive()
        let recorder = FakeRecorder()
        let state = AppState.fixture(settings: settings, audioRecorder: recorder,
            transcriber: RestartTranscriber(), transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
            recordingArchive: archive)
        state.triggerPressed()
        state.triggerReleased()
        await eventually("The old run never reached its cleanup") { await archive.isWaiting }
        state.cancelRequested()
        state.triggerPressed()
        await eventually { recorder.startCallCount == 2 }
        await archive.resume()
        // The old run's code after the discard is queued on the main actor before this check resumes.
        await eventually("The old run's cleanup never returned") { await archive.discardReturned }
        #expect(state.pipelineState == .recording, "Old run changed the new run's state after async cleanup")
        state.cancelRequested()
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
private actor ReviewCleanupArchive: RecordingArchiving {
    var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    var didWait = false
    private(set) var discardReturned = false
    func beginEntry(id: UUID) async throws -> URL { FileManager.default.temporaryDirectory.appending(path: "SyrupReview-\(id).wav") }
    func commitEntry(id: UUID, localeID: String, appleTranscript: String) async {}
    func discardEntry(id: UUID) async -> Bool {
        guard didWait == false else { return true }; didWait = true
        await withCheckedContinuation { waiter = $0 }
        discardReturned = true
        return true
    }
    func unresolvedDeletions() async -> Set<UUID> { [] }
    func resume() { waiter?.resume(); waiter = nil }
    func pendingEntryCounts() async -> AsyncStream<Int> {
        let count = await pendingEntries().count
        return AsyncStream { $0.yield(count); $0.finish() }
    }

    func pendingEntries() async -> [RecordingSidecar] { [] }
    func audioFileURL(id: UUID) async -> URL { FileManager.default.temporaryDirectory }
    func recordAttempt(id: UUID) async -> Int { 0 }
    func deleteEntry(id: UUID) async -> Bool { true }
    func deleteAll() async throws {}
}


private actor RestartTranscriber: Transcriber {
    private var count = 0
    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        count += 1
        if count == 1 { throw TranscriptionError.speechRecognitionAccessDenied }
        for try await _ in audio { try Task.checkCancellation() }
        try Task.checkCancellation()
        return "fixture"
    }
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
