import AVFoundation
import Foundation
import KeyboardShortcuts
import Testing
import Synchronization
@testable import Syrup

@MainActor
struct StaleAndFailedStateTests {
    @Test func sseAcceptsCRLFLikeLF() throws {
        let payload = #"data: {"choices":[{"delta":{"content":"hello"}}]}"#
        var control = OpenAISSEParser()
        #expect(try control.append(payload + "\n\ndata: [DONE]\n\n") == [.delta("hello"), .done])
        var parser = OpenAISSEParser()
        let events = try parser.append(payload + "\r\n\r\ndata: [DONE]\r\n\r\n")
        #expect(events == [.delta("hello"), .done])
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func sseAcceptsLineEndingsSplitAcrossChunks(ending: String) throws {
        let payload = #"data: {"choices":[{"delta":{"content":"Olá"}}]}"# + ending + ending + "data: [DONE]" + ending
        var parser = OpenAISSEParser()
        var events: [OpenAISSEEvent] = []
        for scalar in payload.unicodeScalars { events += try parser.append(String(scalar)) }
        events += try parser.finish()
        #expect(events == [.delta("Olá"), .done])
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func streamCompletesWithSupportedLineEndings(ending: String) async throws {
        let bytes = AsyncThrowingStream<UInt8, any Error>.makeStream()
        let payload = #"data: {"choices":[{"delta":{"content":"Olá"}}]}"# + ending + ending + "data: [DONE]" + ending
        for byte in payload.utf8 { bytes.continuation.yield(byte) }
        // Keep the transport open: DONE must finish consumption on its own.
        defer { bytes.continuation.finish() }
        let output = Mutex("")
        try await withOperationTimeout(.seconds(2), error: TranslationError.timedOut) {
            try await OpenAICompatibleTransformer.consumeSSE(bytes: bytes.stream, endpointHost: "fixture",
                inactivityTimeout: .seconds(30), inactivitySleeper: { try await Task.sleep(for: $0) },
                onDelta: { delta in output.withLock { $0 += delta } })
        }
        #expect(output.withLock { $0 } == "Olá")
    }

    @Test func pauseUnregistersShortcutsAndResumeUsesCurrentWorkflows() {
        let suite = testDomainName("SyrupHotkeyCorrection")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("fixture")), transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster())
        let registration = CorrectionHotkeyRegistration()
        let controller = HotkeyController(appState: state, registration: registration)
        let removed = UUID()
        let added = UUID()
        controller.rebuildWorkflowShortcuts(workflowIDs: [removed])
        controller.setCancelShortcutEnabled(true)
        let enableCount = registration.enableCount
        controller.rebuildWorkflowShortcuts(workflowIDs: [removed])
        #expect(registration.enableCount == enableCount)
        controller.setListening(false)
        #expect(registration.enabled.isEmpty)
        controller.rebuildWorkflowShortcuts(workflowIDs: [added])
        #expect(registration.enabled.isEmpty)
        controller.setCancelShortcutEnabled(false)
        controller.setListening(true)
        #expect(registration.enabled == [.dictate, .revise, .pasteLast, .dictateWorkflow(added)])
        #expect(!registration.enabled.contains(.dictateWorkflow(removed)))
    }

    @Test func appPauseKeepsEditedWorkflowShortcutsDetached() {
        let suite = testDomainName("SyrupPauseCorrection")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        let state = AppState.fixture(settings: settings,
            transcriberAssetManager: TranscriberAssetManager(prepare: { _ in .installed("fixture") }),
            audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("fixture")),
            transformer: FakeTextTransformer(.success("fixture")), pasteboard: SpyPasteboard(),
            feedback: SpyFeedback(), autoPaster: SpyAutoPaster())
        let registration = CorrectionHotkeyRegistration()
        state.installHotkeys(registration: registration)
        #expect(registration.enabled.contains(.dictate))
        state.isHotkeyPaused = true
        let newID = settings.addWorkflow(from: WorkflowTemplate.templates()[0])
        registration.enabled.insert(.dictate)
        registration.enabled.insert(.dictateWorkflow(newID))
        state.refreshWorkflowHotkeys()
        #expect(registration.enabled.isEmpty)
        state.isHotkeyPaused = false
        #expect(registration.enabled.contains(.dictateWorkflow(newID)))
        #expect(!registration.enabled.contains(.cancelDictation))
    }

    @Test func oldConnectionSuccessCannotReplaceNewFailure() async {
        let model = EndpointConnectionTest()
        let gate = ConnectionTestGate()
        let old = model.begin()
        let task = Task { await model.run(old) { await gate.wait() } }
        await gate.waitUntilStarted()
        let current = model.begin()
        await model.run(current) { throw TranslationError.apiKeyRejected }
        gate.resume()
        await task.value
        #expect(model.status == .failure("API key rejected"))
    }

    @Test func unreadableSavedKeyDoesNotFallBackToEnvironment() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupKeyReadCorrection"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = KeychainStore(service: "fixture", storageDirectory: directory)
        try store.save("fixture-value")
        try Data([0xff]).write(to: directory.appending(path: "fixture/apiKey.secret"))
        await #expect(throws: KeychainStoreError.readFailed) {
            _ = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
                baseURLString: "https://original.invalid/v1", modelName: "fixture", keychainStore: store,
                environment: ["OPENAI_COMPATIBLE_URL": "https://fallback.invalid/v1",
                    "OPENAI_COMPATIBLE_MODEL": "fixture", "OPENAI_COMPATIBLE_API_KEY": "fixture-value"])
        }
    }

    @Test func changedEndpointIgnoresOldSuccessAndFailure() async {
        let model = EndpointConnectionTest()
        let old = model.begin()
        model.invalidate()
        var startedStaleRequest = false
        await model.run(old) { startedStaleRequest = true }
        #expect(!startedStaleRequest)
        #expect(model.status == .idle)
        let request = model.begin()
        await model.run(request) {
            model.invalidate()
            throw TranslationError.apiKeyRejected
        }
        #expect(model.status == .idle)
        let latest = model.begin()
        await model.run(latest) {}
        #expect(model.status == .success)
        model.invalidate()
        #expect(model.status == .idle)
    }

    @Test func audioStagesPreserveUpstreamFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupAudioFailure"))
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (source, continuation) = AudioBufferSequence.makeStream()
        let metered = AudioLevelTap.attach(to: source) { _ in }
        let tee = RecordingTee.attach(to: metered, fileURL: directory.appending(path: "fixture.wav"))
        continuation.finish(throwing: AudioRecordingError.audioBufferOverflow)
        await #expect(throws: AudioRecordingError.audioBufferOverflow) {
            for try await _ in tee.stream {}
        }
        await tee.waitForCompletion()
    }

    @Test func archiveCountsFollowCommitsDeletesAndNewSubscribers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupCountCorrection"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let counts = await archive.pendingEntryCounts()
        #expect(try await nextCount(counts) == 0)
        let id = UUID()
        _ = try await archive.beginEntry(id: id)
        await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "fixture")
        #expect(try await nextCount(counts) == 1)
        await archive.deleteEntry(id: id)
        #expect(try await nextCount(counts) == 0)
        let next = await archive.pendingEntryCounts()
        #expect(try await nextCount(next) == 0)
        let otherID = UUID()
        _ = try await archive.beginEntry(id: otherID)
        await archive.commitEntry(id: otherID, localeID: "pt-BR", appleTranscript: "fixture")
        #expect(try await nextCount(next) == 1)
        try await archive.deleteAll()
        #expect(try await nextCount(next) == 0)
    }

    private func nextCount(_ counts: AsyncStream<Int>) async throws -> Int? {
        try await withOperationTimeout(.seconds(2), error: TranslationError.timedOut) {
            await counts.first { _ in true }
        }
    }

    @Test func stereoMeterHandlesProductionInterleavedFormat() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        let samples = try #require(buffer.floatChannelData)[0]
        for frame in 0..<8 { samples[frame * 2] = 0.2; samples[frame * 2 + 1] = 0.6 }
        let rms = try #require(buffer.rmsLevel)
        #expect(abs(rms - sqrt(0.2)) < 0.00001)
    }

    @Test func failedCredentialDeletionMustNotLookSuccessful() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupCredentialAudit"))
        let secretDirectory = directory.appending(path: "audit")
        let secret = secretDirectory.appending(path: "apiKey.secret")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secretDirectory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = KeychainStore(service: "audit", storageDirectory: directory)
        try store.save("fixture-value")
        #expect(try store.load() == "fixture-value")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: secretDirectory.path)
        #expect(throws: KeychainStoreError.deleteFailed) { try store.delete() }
        #expect(throws: KeychainStoreError.readFailed) { _ = try store.load() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: secretDirectory.path)
        let remainsOnDisk = FileManager.default.fileExists(atPath: secret.path)
        #expect(remainsOnDisk)
    }

    @Test func productionLevelTapOverflowAfterReleaseMustPreventDelivery() async throws {
        let suite = testDomainName("SyrupAudioAudit")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.showRecordingCue = true
        settings.playSounds = false
        let recorder = try AuditBurstRecorder()
        let cue = AuditCue()
        let transcriber = FakeTranscriber(.suspended)
        let clipboard = SpyPasteboard()
        let state = AppState.fixture(settings: settings, audioRecorder: recorder, transcriber: transcriber,
            transformer: FakeTextTransformer(.success("truncated output")), pasteboard: clipboard,
            feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
            recordingCue: cue)
        state.triggerPressed()
        await transcriber.waitForCall()
        await eventually { cue.levelCount == 1 }
        #expect(cue.levelCount == 1)
        state.triggerReleased()
        await eventually { cue.levelCount == AudioBufferStream.capacity }
        #expect(recorder.rawDropped == false)
        #expect(cue.levelCount == AudioBufferStream.capacity)
        // This main-actor hop queues after the tap's overflow notification.
        await Task { @MainActor in }.value
        await transcriber.succeed("partial audio transcript")
        await eventually { state.pipelineState == .idle || state.pipelineState.isError }
        #expect(clipboard.writes.isEmpty)
        #expect(state.pipelineState.isError)
        state.cancelRequested()
    }

    @Test func lateCaptureOverflowMustPreventDelivery() async throws {
        let suite = testDomainName("SyrupAudit")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.showRecordingCue = false
        settings.playSounds = false
        let recorder = AuditFailureRecorder()
        let transcriber = FakeTranscriber(.suspended)
        let clipboard = SpyPasteboard()
        let state = AppState.fixture(settings: settings, audioRecorder: recorder, transcriber: transcriber,
            transformer: FakeTextTransformer(.success("truncated output")), pasteboard: clipboard,
            feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
        state.triggerPressed()
        await transcriber.waitForCall()
        state.triggerReleased()
        await eventually { state.pipelineState == .transcribing }
        #expect(state.pipelineState == .transcribing)
        recorder.onFailure?(AudioRecordingError.audioBufferOverflow)
        await transcriber.succeed("partial audio transcript")
        await eventually { state.pipelineState == .idle || state.pipelineState.isError }
        #expect(clipboard.writes.isEmpty)
        #expect(state.pipelineState.isError)
        state.cancelRequested()
    }
}

@MainActor private final class AuditFailureRecorder: AudioRecording {
    var onFailure: (@MainActor (any Error) -> Void)?
    private var continuation: AudioBufferSequence.Continuation?
    func start() async throws -> AudioBufferSequence {
        let pair = AudioBufferSequence.makeStream()
        continuation = pair.continuation
        return pair.stream
    }
    func stop() { continuation?.finish(); continuation = nil }
}

@MainActor private final class AuditCue: RecordingCuePresenting {
    var levelCount = 0
    func apply(_ state: RecordingCueState) {}
    func updateLevel(_ level: Double) { levelCount += 1 }
    func updateTranscript(_ text: String) {}
}

@MainActor private final class AuditBurstRecorder: AudioRecording {
    private var continuation: AudioBufferSequence.Continuation?
    private let buffer: AVAudioPCMBuffer
    var rawDropped = false
    init() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: true))
        buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.1
    }
    func start() async throws -> AudioBufferSequence {
        let pair = AudioBufferStream.make()
        continuation = pair.continuation
        rawDropped = !AudioBufferStream.yield(buffer, to: pair.continuation)
        return pair.stream
    }
    func finish() async throws {
        guard let continuation else { return }
        for _ in 0..<AudioBufferStream.capacity {
            if !AudioBufferStream.yield(buffer, to: continuation) { rawDropped = true }
        }
        continuation.finish()
        self.continuation = nil
    }
    func stop() { continuation?.finish(); continuation = nil }
}

@MainActor private final class CorrectionHotkeyRegistration: HotkeyRegistering {
    var enabled: Set<KeyboardShortcuts.Name> = []
    var enableCount = 0
    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {}
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {}
    func enable(_ name: KeyboardShortcuts.Name) { enabled.insert(name); enableCount += 1 }
    func disable(_ name: KeyboardShortcuts.Name) { enabled.remove(name) }
}

@MainActor private final class ConnectionTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
