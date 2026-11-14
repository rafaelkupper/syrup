import ApplicationServices
import Foundation
import Synchronization
import Testing
@testable import Syrup

@Suite(.serialized)
@MainActor
struct RecoveryReliabilityTests {
    private let defaultsCleanup = RecoveryDefaultsCleanup()
    @Test
    func retryPreservesPrivateProviderDespiteWorkflowAndGlobalChanges() async throws {
        let settings = settings()
        settings.translationProvider = .openAICompatible
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.translationProvider = .appleOnDevice }
        let provider = RecoveryRoutingProvider(failFirst: true)
        let history = HistoryStore()
        let state = AppState.fixture(
            settings: settings, history: history, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("Private fixture input")), transformerProvider: provider,
            pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster(),
            errorResetDelayNanoseconds: 60_000_000_000, maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock()
        )
        state.triggerPressed()
        state.triggerReleased()
        await settle(state)
        let failed = try #require(history.records.first)
        #expect(failed.provider == .appleOnDevice)
        #expect(failed.canRetryWithOriginalProvider)
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.translationProvider = .codexCLI }
        state.retryTranslation(recordID: failed.id)
        await settle(state)
        #expect(await provider.providers == [.appleOnDevice, .appleOnDevice])
        #expect(history.records.first?.provider == .appleOnDevice)

        state.retryTranslation(recordID: failed.id, using: .openAICompatible)
        await settle(state)
        #expect(await provider.providers == [.appleOnDevice, .appleOnDevice, .openAICompatible])
        #expect(history.records.first?.provider == .openAICompatible)
    }

    @Test
    func legacyFailureNeedsExplicitProviderChoice() async throws {
        let history = HistoryStore()
        let record = DictationRecord(
            id: UUID(), finishedAt: .now, transcript: "Fixture input", output: nil,
            transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: .failed(message: "Rate limited")
        )
        history.append(record)
        let transformer = FakeTextTransformer(.success("Complete fixture output"))
        let state = state(settings: settings(), history: history, transformer: transformer)
        #expect(record.canRetry)
        #expect(record.canRetryWithOriginalProvider == false)
        state.retryTranslation(recordID: record.id)
        #expect(await transformer.callCount == 0)
        state.retryTranslation(recordID: record.id, using: .appleOnDevice)
        await settle(state)
        #expect(await transformer.receivedText == "Fixture input")
        #expect(history.records.first?.provider == .appleOnDevice)
    }

    @Test(arguments: [false, true])
    func incompleteResponseNeverCommitsOutput(streaming: Bool) async throws {
        for reason in ["length", "content_filter"] {
            let session = session(mode: .completion(reason: reason))
            defer { session.invalidateAndCancel() }
            let settings = settings()
            settings.showRecordingCue = streaming
            let pasteboard = SpyPasteboard()
            let history = HistoryStore()
            let feedback = SpyFeedback()
            let state = state(
                settings: settings, history: history, transformer: try transformer(session: session),
                pasteboard: pasteboard, feedback: feedback, cue: streaming ? RecoveryCue() : nil
            )
            state.triggerPressed()
            state.triggerReleased()
            await settle(state)
            #expect(state.pipelineState.isError)
            #expect(pasteboard.writes.isEmpty)
            #expect(feedback.successSoundCount == 0)
            #expect(history.records.first?.output == nil)
            #expect(history.records.first?.canRetryWithOriginalProvider == true)
            #expect(state.canCopyPendingResult == false)
            // Shown or not, every run streams its request; the cue only decides what is displayed.
            #expect(RecoveryURLProtocol.requests.withLock { $0 } == [true])
        }
    }

    @Test
    func incompleteDirectTypingWarnsAboutAlreadyPostedPrefix() async throws {
        let session = session(mode: .completion(reason: "length"))
        defer { session.invalidateAndCancel() }
        let settings = settings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        typist.postsTextOnAppend = true
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("Fixture input")),
            transformer: try transformer(session: session), pasteboard: pasteboard, feedback: feedback,
            autoPaster: SpyAutoPaster(), streamingTypistFactory: { typist },
            errorResetDelayNanoseconds: 60_000_000_000, maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
            captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) }
        )
        state.triggerPressed()
        state.triggerReleased()
        await settle(state)
        #expect(typist.hasPostedText)
        #expect(typist.cancelCount > 0)
        #expect(pasteboard.writes.isEmpty)
        #expect(feedback.successSoundCount == 0)
        guard case .error(let message) = state.pipelineState else { Issue.record("Expected a failure"); return }
        #expect(message.contains("partial text may remain"))
    }

    @Test(arguments: [false, true])
    func completeAndLegacyResponsesStillDeliver(streaming: Bool) async throws {
        for reason in [Optional("stop"), nil] {
            let session = session(mode: .completion(reason: reason))
            defer { session.invalidateAndCancel() }
            let settings = settings()
            settings.showRecordingCue = streaming
            let pasteboard = SpyPasteboard()
            let state = state(
                settings: settings, transformer: try transformer(session: session),
                pasteboard: pasteboard, cue: streaming ? RecoveryCue() : nil
            )
            state.triggerPressed()
            state.triggerReleased()
            await settle(state)
            #expect(state.pipelineState == .idle)
            #expect(pasteboard.writes == ["Complete fixture output"])
        }
    }

    @Test
    func atomicOnlyEndpointWorksWithDefaultPreviewAfterConnectionTest() async throws {
        let session = session(mode: .atomicOnly)
        defer { session.invalidateAndCancel() }
        let configuration = try configuration()
        try await OpenAICompatibleEndpointTester(session: session).testConnection(configuration: configuration)
        let settings = settings()
        #expect(settings.showRecordingCue)
        #expect(settings.autoPasteEnabled == false)
        #expect(settings.streamingDeliveryEnabled == false)
        let pasteboard = SpyPasteboard()
        let state = state(
            settings: settings, transformer: try transformer(session: session),
            pasteboard: pasteboard, cue: RecoveryCue()
        )
        state.triggerPressed()
        state.triggerReleased()
        await settle(state)
        #expect(state.pipelineState == .idle)
        #expect(pasteboard.writes == ["Complete fixture output"])
        // The connection test sends the streamed request a run sends; this server answers both in JSON.
        #expect(RecoveryURLProtocol.requests.withLock { $0 } == [true, true])
    }

    @Test
    func explicitStreamingRejectionFallsBackOnceBeforeOutput() async throws {
        let session = session(mode: .rejection(status: 422, param: "stream", code: "unsupported_parameter"))
        defer { session.invalidateAndCancel() }
        let pasteboard = SpyPasteboard()
        let state = state(
            settings: settings(), transformer: try transformer(session: session),
            pasteboard: pasteboard, cue: RecoveryCue()
        )
        state.triggerPressed()
        state.triggerReleased()
        await settle(state)
        #expect(state.pipelineState == .idle)
        #expect(pasteboard.writes == ["Complete fixture output"])
        #expect(RecoveryURLProtocol.requests.withLock { $0 } == [true, false])
    }

    @Test(arguments: [400, 401, 429, 500])
    func unrelatedHTTPFailureNeverRetries(status: Int) async throws {
        let session = session(mode: .rejection(status: status, param: "model", code: "unsupported_parameter"))
        defer { session.invalidateAndCancel() }
        let pasteboard = SpyPasteboard()
        let state = state(
            settings: settings(), transformer: try transformer(session: session),
            pasteboard: pasteboard, cue: RecoveryCue()
        )
        state.triggerPressed()
        state.triggerReleased()
        await settle(state)
        #expect(state.pipelineState.isError)
        #expect(pasteboard.writes.isEmpty)
        #expect(RecoveryURLProtocol.requests.withLock { $0 } == [true])
    }

    @Test(arguments: [false, true])
    func interruptedOrMalformedStreamNeverRetries(malformed: Bool) async throws {
        let session = session(mode: .brokenStream(malformed: malformed))
        defer { session.invalidateAndCancel() }
        let pasteboard = SpyPasteboard()
        let state = state(
            settings: settings(), transformer: try transformer(session: session),
            pasteboard: pasteboard, cue: RecoveryCue()
        )
        state.triggerPressed()
        state.triggerReleased()
        await settle(state)
        #expect(state.pipelineState.isError)
        #expect(pasteboard.writes.isEmpty)
        #expect(RecoveryURLProtocol.requests.withLock { $0 } == [true])
    }

    @Test(arguments: [false, true])
    func clipboardRecoveryCopiesWithoutRepeatingGeneration(streaming: Bool) async throws {
        let session = session(mode: .completion(reason: "stop"))
        defer { session.invalidateAndCancel() }
        let settings = settings()
        settings.showRecordingCue = streaming
        let pasteboard = RecoverablePasteboard()
        let history = HistoryStore()
        let feedback = SpyFeedback()
        let state = state(
            settings: settings, history: history, transformer: try transformer(session: session),
            pasteboard: pasteboard, feedback: feedback, cue: streaming ? RecoveryCue() : nil
        )
        state.triggerPressed()
        state.triggerReleased()
        await settle(state)
        #expect(state.pipelineState.isError)
        #expect(state.canCopyPendingResult)
        #expect(state.lastResult == nil)
        #expect(history.records.isEmpty)
        #expect(feedback.successSoundCount == 0)
        pasteboard.failuresRemaining = 1
        state.copyPendingResult()
        #expect(state.canCopyPendingResult)
        #expect(history.records.isEmpty)
        state.copyPendingResult()
        #expect(state.pipelineState == .idle)
        #expect(state.canCopyPendingResult == false)
        #expect(pasteboard.writes == ["Complete fixture output"])
        #expect(history.records.first?.outcome == .success)
        #expect(feedback.successSoundCount == 1)
        // Shown or not, every run streams its request; the cue only decides what is displayed.
        #expect(RecoveryURLProtocol.requests.withLock { $0 } == [true])
    }

    @Test
    func selectionIsReadBeforeDelayedDeliveryCapture() async throws {
        let settings = settings()
        settings.autoPasteEnabled = true
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.input = .selection }
        let reader = RecoverySelectionReader(.text("Original selection"))
        let gate = RecoveryCaptureGate()
        let transformer = FakeTextTransformer(.success("Complete fixture output"))
        let paster = SpyAutoPaster()
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("unused")),
            transformer: transformer, pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: paster,
            maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(), selectionReader: reader,
            captureDeliveryTarget: { _ in await gate.wait(); return DeliveryTarget(checkCurrent: { false }) }
        )
        state.triggerPressed()
        await waitUntil { gate.waiter != nil }
        #expect(reader.captureCount == 1)
        reader.selection = .text("Selection in a different app")
        gate.release()
        await settle(state)
        #expect(await transformer.receivedText == "Original selection")
        #expect(paster.pasteCount == 0)
        #expect(state.history.records.first?.transcript == "")
    }

    @Test
    func failedSelectionDeliveryStaysVolatileUntilExplicitCopy() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupRecoveryHistory"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = settings()
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.input = .selection }
        let history = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        await settings.attachedOptIns(history: history).setPersistHistory(true)
        let transformer = FakeTextTransformer(.success("Transformed fixture output"))
        let pasteboard = RecoverablePasteboard()
        let state = AppState.fixture(
            settings: settings, history: history, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("unused")), transformer: transformer,
            pasteboard: pasteboard, feedback: SpyFeedback(), autoPaster: SpyAutoPaster(),
            errorResetDelayNanoseconds: 60_000_000_000, maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
            selectionReader: RecoverySelectionReader(.text("Private selected fixture"))
        )
        state.triggerPressed()
        await settle(state)
        await history.flush()
        let file = directory.appending(path: "history.json")
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        #expect(state.canCopyPendingResult)
        state.copyPendingResult()
        await history.flush()
        #expect(await transformer.callCount == 1)
        #expect(history.records.first?.transcript == "")
        let encoded = try String(contentsOf: file, encoding: .utf8)
        #expect(encoded.contains("Private selected fixture") == false)
        #expect(encoded.contains("Transformed fixture output"))
    }

    @Test
    func failedRevisionDeliveryRecoversGeneratedRevisionWithoutLosingBase() async throws {
        let settings = settings()
        let history = HistoryStore()
        history.append(DictationRecord(
            id: UUID(), finishedAt: .now, transcript: "Initial fixture", output: "Base fixture output",
            transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: .success, provider: .appleOnDevice
        ))
        let transformer = FakeTextTransformer(.success("Revised fixture output"))
        let pasteboard = RecoverablePasteboard()
        let state = state(settings: settings, history: history, transformer: transformer, pasteboard: pasteboard)
        state.revisionTriggerPressed()
        state.revisionTriggerReleased()
        await settle(state)
        #expect(state.canCopyPendingResult)
        #expect(state.lastResult == "Base fixture output")
        #expect(history.records.count == 1)
        state.copyPendingResult()
        #expect(state.lastResult == "Revised fixture output")
        #expect(await transformer.receivedText == "Base fixture output")
        #expect(await transformer.callCount == 1)
        #expect(pasteboard.writes == ["Revised fixture output"])
    }

    @Test
    func cancellationBeforeDeliveryCreatesNoRecoveryOrHistory() async {
        let transformer = FakeTextTransformer(.suspended)
        let pasteboard = SpyPasteboard()
        let state = state(settings: settings(), transformer: transformer, pasteboard: pasteboard)
        state.triggerPressed()
        state.triggerReleased()
        await transformer.waitForCall()
        state.cancelRequested()
        await transformer.waitForCancellation()
        #expect(state.pipelineState == .idle)
        #expect(state.canCopyPendingResult == false)
        #expect(state.history.records.isEmpty)
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func cancellationDuringSourceCaptureIgnoresLateSelection() async {
        let settings = settings()
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.input = .selection }
        let reader = RecoverySelectionReader(.text("Late private fixture"))
        let gate = RecoveryCaptureGate()
        reader.gate = gate
        let transformer = FakeTextTransformer(.success("unused"))
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("unused")),
            transformer: transformer, pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster(),
            maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(), selectionReader: reader
        )
        state.triggerPressed()
        await waitUntil { gate.waiter != nil }
        state.cancelRequested()
        gate.release()
        await state.waitForPendingWork()
        #expect(state.pipelineState == .idle)
        #expect(await transformer.callCount == 0)
        #expect(state.history.records.isEmpty)
        #expect(state.canCopyPendingResult == false)
    }

    @Test
    func selectionDeliveryUsesCapturedSourceWithoutRecapturingAnotherField() async throws {
        let settings = settings()
        settings.autoPasteEnabled = true
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.input = .selection }
        let reader = RecoverySelectionReader(.text("Original selection"))
        reader.source = DeliveryTarget(checkCurrent: { false })
        var recaptures = 0
        let paster = SpyAutoPaster()
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("unused")),
            transformer: FakeTextTransformer(.success("Complete fixture output")), pasteboard: SpyPasteboard(),
            feedback: SpyFeedback(), autoPaster: paster, maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
            selectionReader: reader,
            captureDeliveryTarget: { _ in recaptures += 1; return DeliveryTarget(checkCurrent: { true }) }
        )
        state.triggerPressed()
        await settle(state)
        #expect(recaptures == 0)
        #expect(paster.pasteCount == 0)
    }

    @Test(arguments: [false, true])
    func changedSourceFailsSelectionOrOmitsVoiceContext(voice: Bool) async throws {
        let settings = settings()
        settings.updateWorkflow(id: settings.activeWorkflow.id) {
            $0.input = voice ? .voice : .selection
            $0.includeSelectionContext = voice
        }
        let transformer = FakeTextTransformer(.success("Complete fixture output"))
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("Fixture voice")),
            transformer: transformer, pasteboard: SpyPasteboard(), feedback: SpyFeedback(), autoPaster: SpyAutoPaster(),
            errorResetDelayNanoseconds: 60_000_000_000, maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
            selectionReader: RecoverySelectionReader(.sourceChanged)
        )
        state.triggerPressed()
        if voice { state.triggerReleased() }
        await settle(state)
        #expect(await transformer.callCount == (voice ? 1 : 0))
        #expect(state.pipelineState.isError == !voice)
        if voice { #expect(await transformer.receivedText == "Fixture voice") }
        else { #expect(state.history.records.isEmpty) }
    }

    private func settings() -> AppSettings {
        let name = testDomainName("SyrupRecoveryTests")
        let defaults = TestDefaults(suiteName: name)!
        // This suite never writes to the real app's defaults.
        defaults.removePersistentDomain(forName: name)
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        defaultsCleanup.names.append(name)
        return settings
    }

    private func state(
        settings: AppSettings,
        history: HistoryStore = HistoryStore(),
        transformer: any TextTransformer,
        pasteboard: any PasteboardWriting = SpyPasteboard(),
        feedback: SpyFeedback = SpyFeedback(),
        cue: (any RecordingCuePresenting)? = nil
    ) -> AppState {
        AppState.fixture(
            settings: settings, history: history, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("Fixture input")), transformer: transformer,
            pasteboard: pasteboard, feedback: feedback, autoPaster: SpyAutoPaster(),
            errorResetDelayNanoseconds: 60_000_000_000, maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
            recordingCue: cue
        )
    }

    private func settle(_ state: AppState) async {
        await settleRun(state)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        await eventually { condition() }
    }

    private func configuration() throws -> OpenAICompatibleConfiguration {
        try .userSettings(baseURLString: "https://fixture.invalid/v1", apiKey: "", modelName: "fixture")
    }

    private func transformer(session: URLSession) throws -> OpenAICompatibleTransformer {
        OpenAICompatibleTransformer(configuration: try configuration(), session: session)
    }

    private func session(mode: RecoveryURLProtocol.Mode) -> URLSession {
        RecoveryURLProtocol.mode.withLock { $0 = mode }
        RecoveryURLProtocol.requests.withLock { $0 = [] }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecoveryURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

@MainActor private final class RecoveryDefaultsCleanup {
    var names: [String] = []
    deinit {
        for name in names { TestDefaults.removeSuite(name) }
    }
}

@MainActor private final class RecoveryCue: RecordingCuePresenting {
    func apply(_ state: RecordingCueState) {}
    func updateLevel(_ level: Double) {}
    func updateTranscript(_ text: String) {}
    func updateOutput(_ text: String) -> Bool { true }
}

@MainActor private final class RecoverySelectionReader: SelectionReading {
    var selection: SelectionCapture
    var source: DeliveryTarget?
    var gate: RecoveryCaptureGate?
    private(set) var captureCount = 0
    init(_ selection: SelectionCapture) { self.selection = selection }
    func captureForRun(processID: pid_t?) async -> RunSelectionCapture {
        if let gate { await gate.wait() }
        captureCount += 1
        return RunSelectionCapture(selection: selection, source: source)
    }
}

@MainActor private final class RecoveryCaptureGate {
    var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { waiter = $0 } }
    func release() { waiter?.resume(); waiter = nil }
}

private final class RecoverablePasteboard: PasteboardWriting {
    var failuresRemaining = 1
    private(set) var writes: [String] = []
    func write(_ string: String) throws {
        if failuresRemaining > 0 { failuresRemaining -= 1; throw ClipboardError.writeFailed }
        writes.append(string)
    }
}

private actor RecoveryRoutingProvider: TransformerSource {
    private(set) var providers: [TranslationProvider] = []
    let failFirst: Bool
    init(failFirst: Bool) { self.failFirst = failFirst }
    func transformer(for provider: TranslationProvider, instruction: String) async -> any TextTransformer {
        providers.append(provider)
        if failFirst, providers.count == 1 {
            return StaticErrorTextTransformer(error: TranslationError.onDeviceContextExceeded)
        }
        return FakeTextTransformer(.success("Complete fixture output"))
    }
}

private final class RecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable {
        case atomicOnly
        case completion(reason: String?)
        case rejection(status: Int, param: String, code: String)
        case brokenStream(malformed: Bool)
    }
    static let mode = Mutex(Mode.atomicOnly)
    static let requests = Mutex<[Bool]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let requestBody = (try JSONSerialization.jsonObject(with: bodyData())) as? [String: Any]
            let streaming = requestBody?["stream"] as? Bool == true
            Self.requests.withLock { $0.append(streaming) }
            var status = 200
            var mimeType = "application/json"
            var body = try completion(reason: "stop")
            switch Self.mode.withLock({ $0 }) {
            case .atomicOnly: break
            case .completion(let reason):
                body = try streaming ? stream(reason: reason) : completion(reason: reason)
                if streaming { mimeType = "text/event-stream" }
            case .rejection(let rejectedStatus, let param, let code):
                if streaming {
                    status = rejectedStatus
                    body = try JSONSerialization.data(withJSONObject: ["error": ["param": param, "code": code]])
                }
            case .brokenStream(let malformed):
                mimeType = "text/event-stream"
                let suffix = malformed ? "data: {broken-json}\n\n" : ""
                body = Data(("data: {\"choices\":[{\"delta\":{\"content\":\"Prefix\"}}]}\n\n" + suffix).utf8)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": mimeType]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }

    override func stopLoading() {}

    private func completion(reason: String?) throws -> Data {
        var choice: [String: Any] = ["message": ["role": "assistant", "content": "Complete fixture output"]]
        if let reason { choice["finish_reason"] = reason }
        return try JSONSerialization.data(withJSONObject: ["choices": [choice]])
    }

    private func stream(reason: String?) throws -> Data {
        var choice: [String: Any] = ["delta": [:] as [String: String]]
        if let reason { choice["finish_reason"] = reason }
        let terminal = String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self)
        return Data(("data: {\"choices\":[{\"delta\":{\"content\":\"Complete fixture output\"}}]}\n\n" +
                     "data: \(terminal)\n\ndata: [DONE]\n\n").utf8)
    }

    private func bodyData() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
