import AVFoundation
import Foundation
import Testing
@testable import Syrup

@MainActor
struct PipelineLifecycleRegressionTests {
    private func settings(learning: Bool = false) -> (AppSettings, String) {
        let name = "SyrupReview.\(UUID().uuidString)"
        let settings = AppSettings(userDefaults: UserDefaults(suiteName: name)!, defaultMicrophoneIDProvider: { "" })
        settings.glossaryLearningEnabled = learning
        settings.showRecordingCue = false
        settings.playSounds = false
        return (settings, name)
    }

    @Test func listingPendingMustPreserveActiveWAV() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SyrupReviewArchive.\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let url = try await archive.beginEntry(id: UUID())
        #expect(FileManager.default.fileExists(atPath: url.path))
        _ = await archive.pendingEntries()
        #expect(FileManager.default.fileExists(atPath: url.path), "Listing pending entries deleted an active WAV")
    }

    @Test func cancellationDuringPermissionMustNotLeaveCaptureRunning() async throws {
        let (settings, name) = settings()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let permission = ReviewPermissionGate()
        let capture = ReviewCapture()
        let recorder = AudioRecorder(settings: settings, deviceCatalog: ReviewDeviceCatalog(), microphonePermissionRequester: {
            await permission.wait()
        }, captureSessionFactory: { _, _ in capture })
        let state = AppState(settings: settings, audioRecorder: recorder,
            transcriber: FakeTranscriber(.success("fixture")), transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
        state.triggerPressed()
        for _ in 0..<1000 { if permission.continuation != nil { break }; await Task.yield() }
        #expect(permission.continuation != nil)
        state.cancelRequested()
        permission.continuation?.resume(returning: true)
        permission.continuation = nil
        for _ in 0..<1000 { await Task.yield() }
        #expect(state.pipelineState == .idle)
        #expect(capture.isRunning == false, "Cancelled run started microphone capture after permission returned")
        recorder.stop()
    }

    @Test func oldFailureCleanupMustNotOverwriteNewRun() async throws {
        let (settings, name) = settings(learning: true)
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let archive = ReviewCleanupArchive()
        let recorder = FakeRecorder()
        let state = AppState(settings: settings, audioRecorder: recorder,
            transcriber: RestartTranscriber(), transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
            recordingArchive: archive)
        state.triggerPressed()
        state.triggerReleased()
        for _ in 0..<1000 { if await archive.isWaiting { break }; await Task.yield() }
        #expect(await archive.isWaiting)
        state.cancelRequested()
        state.triggerPressed()
        for _ in 0..<1000 { if recorder.startCallCount == 2 { break }; await Task.yield() }
        #expect(recorder.startCallCount == 2)
        await archive.resume()
        for _ in 0..<1000 { await Task.yield() }
        #expect(state.pipelineState == .recording, "Old run changed the new run's state after async cleanup")
        state.cancelRequested()
    }

    @Test func earlyRecognitionFailureMustStopRecordingWithoutRelease() async throws {
        let (settings, name) = settings()
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(.failure(.speechPermission))
        let state = AppState(settings: settings, audioRecorder: recorder,
            transcriber: transcriber, transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
        state.triggerPressed()
        await transcriber.waitForCall()
        for _ in 0..<1000 { await Task.yield() }
        #expect(state.pipelineState != .recording, "Known speech failure is hidden until the user stops recording")
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
    func beginEntry(id: UUID) async throws -> URL { FileManager.default.temporaryDirectory.appending(path: "SyrupReview-\(id).wav") }
    func commitEntry(id: UUID, localeID: String, appleTranscript: String) async {}
    func discardEntry(id: UUID) async {
        guard didWait == false else { return }; didWait = true
        await withCheckedContinuation { waiter = $0 }
    }
    func resume() { waiter?.resume(); waiter = nil }
    func pendingEntryCounts() async -> AsyncStream<Int> {
        let count = await pendingEntries().count
        return AsyncStream { $0.yield(count); $0.finish() }
    }

    func pendingEntries() async -> [RecordingSidecar] { [] }
    func audioFileURL(id: UUID) async -> URL { FileManager.default.temporaryDirectory }
    func recordAttempt(id: UUID) async -> Int { 0 }
    func deleteEntry(id: UUID) async {}
    func deleteAll() async throws {}
}


private actor RestartTranscriber: Transcriber {
    private var count = 0
    func transcribe(_ audio: AudioBufferSequence, locale: Locale, vocabulary: [String],
                    onPartialTranscript: (@Sendable (String) -> Void)?) async throws -> String {
        count += 1
        if count == 1 { throw TranscriptionError.speechRecognitionAccessDenied }
        for try await _ in audio { try Task.checkCancellation() }
        try Task.checkCancellation()
        return "fixture"
    }
}
