import AVFoundation
import Foundation
import Testing
@testable import Syrup

@MainActor
struct PipelineSafeguardTests {
    @Test func historyDeletionFailurePreservesOptInAndRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupHistoryFailure"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = fixtureSettings()
        settings.persistHistory = true
        let history = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        history.append(record("retained"))
        await history.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        #expect(await history.clear() == false)
        #expect(history.records.count == 1)
        await history.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let state = appState(settings: settings, history: history)
        await state.setPersistHistory(false)
        #expect(settings.persistHistory)
        #expect(history.persistenceError != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path))
        await history.flush()
    }

    @Test func historyDeletionWaitsForQueuedWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupHistoryBarrier"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        for index in 0..<40 { store.append(record("\(index)")) }
        await store.flush()
        let reloaded = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        #expect(reloaded.records.map(\.transcript) == (20..<40).reversed().map(String.init))
        store.append(record("last queued write"))
        #expect(await store.setPersistenceEnabled(false))
        store.append(record("memory only"))
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path) == false)
    }

    @Test func notificationFallbackUsesOriginatingRecordAndIgnoresMissingID() {
        let history = HistoryStore()
        let original = record("original failure", failed: true)
        history.append(original)
        history.append(record("newer failure", failed: true))
        let pasteboard = SpyPasteboard()
        let state = appState(history: history, pasteboard: pasteboard)
        state.copyTranscriptFallback(recordID: original.id)
        state.copyTranscriptFallback(recordID: UUID())
        #expect(pasteboard.writes == ["original failure"])
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
        var sameEditor = true
        var posted: [TypingStep] = []
        let typist = StreamingTypist(sizeThreshold: 1, trustStatus: { true }, secureInputStatus: { false },
            frontmostApplicationID: { "fixture.editor" }, eventPoster: { posted.append($0); return true })
        typist.setTargetValidator { sameEditor }
        try typist.start()
        typist.append("first ")
        await typist.waitForQueuedFlushes()
        let beforeFocusChange = posted
        #expect(beforeFocusChange.isEmpty == false)
        sameEditor = false
        typist.append("second")
        await typist.waitForQueuedFlushes()
        await typist.finish()
        #expect(posted == beforeFocusChange)
        #expect(typist.stopReason == .focusChanged)
    }

    @Test func providerConfigurationIsFrozenBeforeTransformation() async throws {
        let settings = fixtureSettings()
        settings.baseURL = "https://snapshot.invalid/v1"
        settings.modelName = "original-model"
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupSnapshot"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SnapshotURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = AppSettingsTransformerProvider(settings: settings,
            keychainStore: KeychainStore(storageDirectory: directory), session: session, environment: [:])
        let snapshot = provider.snapshot(for: .openAICompatible)
        settings.baseURL = "https://changed.invalid/v1"
        settings.modelName = "changed-model"
        let transformer = await snapshot.transformer(instruction: "fixture")
        let output = try await transformer.transform("fixture", instruction: "fixture")
        #expect(output == "snapshot.invalid original-model")
    }

    @Test func audioBufferOverflowFailsExplicitlyAndBoundsQueue() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        let (stream, continuation) = AudioBufferStream.make()
        for _ in 0..<AudioBufferStream.capacity { #expect(AudioBufferStream.yield(buffer, to: continuation)) }
        #expect(AudioBufferStream.yield(buffer, to: continuation) == false)
        var count = 0
        await #expect(throws: AudioRecordingError.audioBufferOverflow) {
            for try await _ in stream { count += 1 }
        }
        #expect(count == AudioBufferStream.capacity)
    }

    @Test func recognitionFailureCancelsAudioFeedBeforeRelease() async {
        let (audio, continuation) = AsyncStream<Int>.makeStream()
        defer { continuation.finish() }
        await #expect(throws: TranscriptionError.speechRecognitionAccessDenied) {
            try await runWhileMonitoring {
                for await _ in audio { try Task.checkCancellation() }
                try Task.checkCancellation()
                return "must not deliver"
            } monitor: { throw TranscriptionError.speechRecognitionAccessDenied }
        }
    }

    @Test func timeoutReturnsEvenWhenOperationIgnoresCancellation() async {
        let gate = UncooperativeOperation()
        await #expect(throws: TranscriptionError.finalizationTimedOut) {
            try await withOperationTimeout(.milliseconds(20), error: TranscriptionError.finalizationTimedOut) {
                await gate.wait()
            }
        }
        await gate.release()
    }

    @Test func frameworkMonitorCannotHoldTimeoutCleanupOpen() async throws {
        let gate = UncooperativeOperation()
        let frameworkTask = Task<Int, any Error> { await gate.wait() }
        let outcome = try await runWhileMonitoring {
            return "completed"
        } monitor: {
            _ = try await awaitCancellableValue(of: frameworkTask)
        }
        #expect(outcome == "completed")
        #expect(frameworkTask.isCancelled)
        await gate.release()
    }

    @Test func localePreparationsAreIndependentAndDeduplicated() async {
        let gate = LocalePreparationGate()
        let manager = TranscriberAssetManager(prepare: { await gate.prepare($0) })
        manager.prepareSelectedLocale("pt_BR")
        manager.prepareLocales(["pt-BR", "en-US", "en-US"])
        await eventually { await gate.count == 2 }
        #expect(await gate.count == 2)
        await gate.finish("en-US")
        for _ in 0..<50 { await Task.yield() }
        #expect(manager.selectedLocaleAssetState == .checking)
        await gate.finish("pt-BR")
        await eventually { manager.selectedLocaleAssetState == .installed("pt-BR") }
        #expect(manager.selectedLocaleAssetState == .installed("pt-BR"))
        manager.prepareSelectedLocale("en-US")
        #expect(manager.selectedLocaleAssetState == .installed("en-US"))
        #expect(await gate.count == 2)
    }

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
        for _ in 0..<100 { await Task.yield() }
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
        let defaults = UserDefaults(suiteName: testDomainName("SyrupReviewTests"))!
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.showRecordingCue = false
        settings.playSounds = false
        return settings
    }

    private func record(_ transcript: String, failed: Bool = false) -> DictationRecord {
        DictationRecord(id: UUID(), finishedAt: .now, transcript: transcript,
            output: failed ? nil : "output", transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: failed ? .failed(message: "fixture") : .success)
    }

    private func appState(settings: AppSettings? = nil, history: HistoryStore = HistoryStore(),
                          pasteboard: SpyPasteboard = SpyPasteboard()) -> AppState {
        AppState.fixture(settings: settings ?? fixtureSettings(), history: history, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("fixture")), transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: pasteboard, feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
    }
}

private actor UncooperativeOperation {
    private var continuation: CheckedContinuation<Int, Never>?
    private var released = false
    func wait() async -> Int {
        if released { return 1 }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(returning: 1)
        continuation = nil
    }
}

private actor LocalePreparationGate {
    private var continuations: [String: CheckedContinuation<TranscriberAssetManager.AssetState, Never>] = [:]
    private(set) var count = 0
    func prepare(_ id: String) async -> TranscriberAssetManager.AssetState {
        count += 1
        return await withCheckedContinuation { continuations[id] = $0 }
    }
    func finish(_ id: String) { continuations.removeValue(forKey: id)?.resume(returning: .installed(id)) }
}

private final class SnapshotURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let text = "\(request.url!.host!) \(body?["model"] as? String ?? "missing")"
        let response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": text]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private final class OutputPreviewSpy: RecordingCuePresenting {
    private(set) var outputs: [String] = []
    func apply(_ state: RecordingCueState) {}
    func updateLevel(_ level: Double) {}
    func updateTranscript(_ text: String) {}
    func updateOutput(_ text: String) -> Bool { outputs.append(text); return true }
}
