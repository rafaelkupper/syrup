import AVFoundation
import Foundation
import Testing
@testable import Syrup

struct PauseTransformationPolicyTests {
    @Test(arguments: ["http://localhost:11434/v1", "http://LOCALHOST/v1", "http://127.0.0.1/v1",
                      "http://127.255.10.99/v1", "http://[::1]:1234/v1"])
    func loopbackURLsAreLocal(_ value: String) throws {
        #expect(PauseTransformation.isLoopback(try #require(URL(string: value))))
    }

    @Test(arguments: ["http://localhost.example/v1", "http://192.0.2.1/v1", "https://api.openai.com/v1",
                      "http://128.0.0.1", "http://127.0.0.256", "http://[::ffff:127.0.0.1]", "http://127.1"])
    func otherURLsAreNotLocal(_ value: String) throws {
        #expect(!PauseTransformation.isLoopback(try #require(URL(string: value))))
    }

    @Test func equalityIsByteExact() {
        #expect("é" == "e\u{301}")
        #expect(!PauseTransformation.sameInput("é", "e\u{301}"))
        #expect(PauseTransformation.sameInput("same", "same"))
    }

    @Test func correctionAndTrimMatchTheFinalInputPath() {
        let corrections = [Correction(heard: "fixture", replacement: " corrected ")]
        #expect(PauseTransformation.input("  fixture \n", corrections: corrections) == "corrected")
        #expect(PauseTransformation.input(" fixture ", corrections: [Correction(heard: "fixture", replacement: " ")]).isEmpty)
    }

    @Test(arguments: [
        ("http://192.168.1.20:11434/v1", true), ("http://ollama.local/v1", true),
        ("http://localhost:11434/v1", false), ("http://127.0.0.1:1234/v1", false), ("http://[::1]:8080/v1", false),
        ("https://api.openai.com/v1", false), ("not a url", false), ("", false),
    ])
    func onlyPlainHTTPToAnotherMachineIsUnencrypted(value: String, unencrypted: Bool) {
        #expect(EndpointPolicy.isUnencryptedRemote(value) == unencrypted)
    }

    @MainActor @Test func resolvedEndpointControlsEligibilityAndIsFrozen() {
        let name = "SyrupPauseEndpoint.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.baseURL = "http://localhost:1234/v1"
        settings.modelName = "fixture"
        let emptyStore = KeychainStore(storageDirectory: FileManager.default.temporaryDirectory.appending(path: name))
        let remote = AppSettingsTransformerProvider(settings: settings, keychainStore: emptyStore, environment: [
            "OPENAI_COMPATIBLE_URL": "https://example.test/v1",
            "OPENAI_COMPATIBLE_API_KEY": "fixture", "OPENAI_COMPATIBLE_MODEL": "fixture"
        ])
        #expect(!remote.snapshot(for: .openAICompatible).permitsUnfinalizedInput)
        let local = AppSettingsTransformerProvider(settings: settings, keychainStore: emptyStore, environment: [:])
        let snapshot = local.snapshot(for: .openAICompatible)
        settings.baseURL = "https://example.test/v1"
        #expect(snapshot.permitsUnfinalizedInput)
        #expect(!local.snapshot(for: .openAICompatible).permitsUnfinalizedInput)
        #expect(local.snapshot(for: .appleOnDevice).permitsUnfinalizedInput)
        #expect(!local.snapshot(for: .codexCLI).permitsUnfinalizedInput)
    }

    @MainActor @Test func preferenceDefaultsOffAndPersistsAsBool() {
        let name = "SyrupPauseSettings.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        #expect(!settings.transformsOnPause)
        settings.transformsOnPause = true
        #expect(defaults.object(forKey: "transformsOnPause") as? Bool == true)
        #expect(AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" }).transformsOnPause)
    }
}

@MainActor
struct PauseAudioCaptureTests {
    @Test func snapshotsOwnTheirSamplesAndContainTheWholePrefix() async throws {
        let capture = PauseAudioCapture()
        let source = LevelRecorder.buffer(dBFS: -20)
        capture.append(source)
        source.floatChannelData![0][0] = 1
        capture.append(LevelRecorder.buffer(dBFS: -60))
        let audio = try #require(capture.snapshot())
        var frames = 0
        for try await buffer in audio {
            #expect(abs(buffer.floatChannelData![0][0] - 0.1) < 0.0001)
            frames += Int(buffer.frameLength)
        }
        #expect(frames == 8192)
    }

    @Test func capAndStopReleaseTheCopyPermanently() throws {
        let capture = PauseAudioCapture()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 100, channels: 1))
        let full = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9000))
        full.frameLength = 9000
        memset(full.floatChannelData![0], 0, 9000 * MemoryLayout<Float>.size)
        capture.append(full)
        #expect(capture.frameCount == 9000)
        #expect(capture.snapshot() != nil)
        capture.append(full)
        #expect(!capture.isCapturing)
        #expect(capture.frameCount == 0)
        #expect(capture.snapshot() == nil)
        capture.append(LevelRecorder.buffer(dBFS: -20))
        #expect(capture.frameCount == 0)
    }

    @Test func runCancellationReleasesCopiedAudio() {
        let f = PauseFixture()
        defer { f.cleanUp() }
        let run = PipelineRun(configuration: f.settings.runConfiguration(workflowID: nil),
            triggerWorkflowID: nil, triggeredAt: f.clock.now, settings: f.settings,
            activities: SpyProcessActivity(), providerSnapshot: f.provider.snapshot(for: .openAICompatible))
        run.pauseAudio?.append(LevelRecorder.buffer(dBFS: -20))
        #expect(run.pauseAudio?.frameCount == 4096)
        run.cancel()
        #expect(run.pauseAudio?.frameCount == 0)
        #expect(run.pauseAudio?.snapshot() == nil)
        run.endActivity()
    }
}

@MainActor
struct PauseTransformationTests {
    @Test func hitUsesFreshTransformerAndCommitsExactlyOnce() async throws {
        let f = PauseFixture()
        defer { f.cleanUp() }
        f.settings.autoPasteEnabled = true
        f.settings.streamingDeliveryEnabled = true
        await f.start()
        await f.pause()
        #expect(await f.provider.creationCount == 2)
        #expect(await f.prepared.callCount == 0)
        #expect(await f.attempt.callCount == 1)
        #expect(f.pasteboard.writes.isEmpty)
        #expect(f.history.records.isEmpty)
        #expect(await f.attempt.receivedInstruction == f.settings.runConfiguration(workflowID: nil).instruction)
        f.release()
        await pauseWait { f.state.pipelineState == .translating }
        #expect(f.pasteboard.writes.isEmpty)
        await f.attempt.succeed("result")
        await f.completed()
        #expect(f.pasteboard.writes == ["result"])
        #expect(f.history.records.count == 1)
        #expect(f.history.records.first?.transcript == "fixture")
        #expect(f.autoPaster.pasteCount == 1)
        #expect(f.metrics.deliveryModes == [.atomic])
        #expect(f.metrics.pauseOutcomes.map(\.0) == [.hit])
        #expect(f.metrics.pauseOutcomes.map(\.1) == [1])
        #expect(f.metrics.recordedDurations.map(\.0) == [.translation])
        #expect(f.metrics.endedStages.contains(.releaseToClipboard))
    }

    @Test func mismatchCancelsAttemptAndUsesPreparedTransformer() async {
        let f = PauseFixture(final: "changed")
        defer { f.cleanUp() }
        await f.start()
        await f.pause()
        f.release()
        await f.completed()
        await pauseWait { await f.attempt.cancellationCount == 1 }
        #expect(await f.prepared.callCount == 1)
        #expect(await f.prepared.receivedText == "changed")
        #expect(f.pasteboard.writes == ["normal"])
        #expect(f.metrics.pauseOutcomes.map(\.0) == [.miss])
    }

    @Test func escapeDuringAttemptNeverDelivers() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.start()
        await f.pause()
        f.state.cancelRequested()
        await pauseWait { await f.attempt.cancellationCount == 1 }
        #expect(f.state.pipelineState == .idle)
        #expect(f.pasteboard.writes.isEmpty)
        #expect(f.history.records.isEmpty)
        #expect(await f.prepared.callCount == 0)
    }

    @Test func failedAttemptFallsBackWithoutFailedHistory() async {
        let f = PauseFixture(attempt: FakeTextTransformer(.failure(.transformer)))
        defer { f.cleanUp() }
        await f.start()
        await f.pause()
        f.release()
        await f.completed()
        #expect(f.pasteboard.writes == ["normal"])
        #expect(f.history.records.count == 1)
        #expect(f.metrics.pauseOutcomes.map(\.0) == [.failed])
    }

    @Test func sameInputAcrossQuietPeriodsKeepsAttemptAndDifferentInputReplaces() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.start()
        await f.pause()
        f.clock.advance(by: .seconds(1))
        f.recorder.yield(dBFS: -60)
        await pauseSettle()
        #expect(await f.transcriber.offlineCount == 1)
        f.recorder.yield(dBFS: -20)
        await pauseSettle()
        await f.pause()
        #expect(await f.transcriber.offlineCount == 2)
        #expect(await f.provider.creationCount == 2)
        await f.transcriber.setOfflineText("different")
        f.recorder.yield(dBFS: -20)
        await pauseSettle()
        await f.pause(expectAttempt: false)
        await pauseWait { await f.provider.creationCount == 3 }
        #expect(await f.attempt.cancellationCount == 1)
        f.state.cancelRequested()
    }

    @Test(arguments: [TranslationProvider.codexCLI, .openAICompatible])
    func nonlocalProvidersNeverSpeculate(_ provider: TranslationProvider) async {
        let f = PauseFixture(provider: provider, local: provider == .codexCLI)
        defer { f.cleanUp() }
        await f.start()
        await f.pause(expectAttempt: false)
        #expect(await f.provider.creationCount == 1)
        f.release()
        await f.completed()
        #expect(await f.attempt.callCount == 0)
        #expect(f.metrics.pauseOutcomes.isEmpty)
        #expect(await f.transcriber.offlineCount == 0)
    }

    @Test func settingOffStillRecordsQuietTime() async {
        let f = PauseFixture(enabled: false)
        defer { f.cleanUp() }
        await f.start()
        await f.pause(expectAttempt: false)
        f.release()
        await f.completed()
        #expect(f.metrics.quietDurations == [.milliseconds(300)])
        #expect(f.metrics.pauseOutcomes.isEmpty)
        #expect(await f.attempt.callCount == 0)
        #expect(await f.transcriber.offlineCount == 0)
    }

    @Test func startsAtQuietDeadlineWithoutAnyLiveTranscript() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.start()
        f.recorder.yield(dBFS: -60)
        await pauseSettle()
        f.clock.advance(by: .milliseconds(299))
        await pauseSettle()
        #expect(await f.transcriber.offlineCount == 0)
        f.clock.advance(by: .milliseconds(1))
        await pauseWait { await f.attempt.callCount == 1 }
        #expect(await f.transcriber.offlineCount == 1)
        #expect(await f.transcriber.offlineFrames > 0)
        f.state.cancelRequested()
    }

    @Test func loudAudioCancelsPassAndNextQuietStartsAnother() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.transcriber.suspendOffline()
        await f.start()
        await f.pause(expectAttempt: false)
        await pauseWait { await f.transcriber.offlineCount == 1 }
        f.recorder.yield(dBFS: -20)
        await pauseWait { await f.transcriber.offlineCancellationCount == 1 }
        #expect(await f.attempt.callCount == 0)
        await f.pause(expectAttempt: false)
        await pauseWait { await f.transcriber.offlineCount == 2 }
        await f.transcriber.completeOffline()
        await pauseWait { await f.attempt.callCount == 1 }
        f.state.cancelRequested()
    }

    @Test func releaseCancelsPendingPassAndFallsBack() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.transcriber.suspendOffline()
        await f.start()
        await f.pause(expectAttempt: false)
        await pauseWait { await f.transcriber.offlineCount == 1 }
        f.release()
        await f.completed()
        await pauseWait { await f.transcriber.offlineCancellationCount == 1 }
        #expect(await f.attempt.callCount == 0)
        #expect(f.pasteboard.writes == ["normal"])
    }

    @Test(arguments: [false, true]) func unusableOfflinePassFallsBackWithoutRetry(fails: Bool) async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.transcriber.setOfflineFailure(fails)
        await f.transcriber.setOfflineText(" ")
        await f.start()
        await f.pause(expectAttempt: false)
        await pauseWait { await f.transcriber.offlineCount == 1 }
        await pauseSettle()
        f.clock.advance(by: .seconds(1))
        f.recorder.yield(dBFS: -60)
        await pauseSettle()
        #expect(await f.transcriber.offlineCount == 1)
        #expect(await f.attempt.callCount == 0)
        f.release()
        await f.completed()
        #expect(f.pasteboard.writes == ["normal"])
        #expect(f.history.records.count == 1)
    }

    @Test(arguments: [false, true]) func hiddenTranscriptDoesNotPreventPass(cueVisible: Bool) async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        f.settings.showRecordingCue = cueVisible
        f.settings.showLiveTranscript = false
        await f.start()
        await f.pause()
        #expect(await f.transcriber.offlineCount == 1)
        f.state.cancelRequested()
    }

    @Test func canonicallyEqualFinalWithDifferentBytesMisses() async {
        let f = PauseFixture(final: "e\u{301}")
        defer { f.cleanUp() }
        await f.transcriber.setOfflineText("é")
        await f.start()
        await f.pause()
        f.release()
        await f.completed()
        #expect(f.metrics.pauseOutcomes.map(\.0) == [.miss])
        #expect(f.pasteboard.writes == ["normal"])
    }

    @Test func capStopsNewPasses() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.start()
        let format = LevelRecorder.buffer(dBFS: -20).format
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 90 * 48_000)!
        buffer.frameLength = buffer.frameCapacity
        memset(buffer.floatChannelData![0], 0, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        f.recorder.yield(buffer)
        await pauseSettle()
        await f.pause(expectAttempt: false)
        #expect(await f.transcriber.offlineCount == 0)
        f.release()
        await f.completed()
    }

    @Test func offlinePassUsesFrozenLocaleVocabularyAndMode() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        f.settings.preferFastTranscription = true
        await f.start()
        f.settings.preferFastTranscription = false
        await f.pause()
        #expect(await f.transcriber.offlineFast == true)
        #expect(await f.transcriber.offlineLocale == f.settings.runConfiguration(workflowID: nil).dictationLocaleID)
        #expect(await f.transcriber.offlineVocabulary == f.settings.runConfiguration(workflowID: nil).speechVocabulary)
        f.state.cancelRequested()
    }

    @Test func speechResumptionRestartsQuietTimer() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.start()
        f.recorder.yield(dBFS: -60)
        await pauseSettle()
        f.clock.advance(by: .milliseconds(299))
        f.recorder.yield(dBFS: -20)
        await pauseSettle()
        f.clock.advance(by: .seconds(1))
        await pauseSettle()
        #expect(await f.provider.creationCount == 1)
        await f.pause()
        f.state.cancelRequested()
    }

    @Test func releaseTailCannotStartAnAttempt() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.start()
        f.release()
        await pauseSettle()
        f.clock.advance(by: .milliseconds(300))
        f.recorder.yield(dBFS: -60)
        await f.completed()
        #expect(await f.attempt.callCount == 0)
        #expect(f.metrics.pauseOutcomes.map(\.0) == [.none])
    }

    @Test func failureDuringAttemptCancelsWithoutDelivery() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.start()
        await f.pause()
        await f.transcriber.fail()
        f.recorder.yield(dBFS: -60)
        await pauseWait { await f.attempt.cancellationCount == 1 }
        #expect(f.pasteboard.writes.isEmpty)
        #expect(await f.prepared.callCount == 0)
    }

    @Test func onlyAppleVoiceDictationIsEligible() {
        let f = PauseFixture()
        defer { f.cleanUp() }
        let configuration = f.settings.runConfiguration(workflowID: nil)
        for (purpose, voice, model) in [(RunPurpose.revision(base: "fixture"), true, false),
                                       (.transcribeOnly(cleanup: false), true, false),
                                       (.dictation, false, false), (.dictation, true, true)] {
            var config = configuration
            config.purpose = purpose
            let run = PipelineRun(configuration: config, triggerWorkflowID: nil, triggeredAt: f.clock.now,
                settings: f.settings, activities: SpyProcessActivity(), isVoiceInput: voice,
                providerSnapshot: f.provider.snapshot(for: .openAICompatible), speechModel: (model ? f.transcriber : nil, nil))
            #expect(!run.pauseTransformationEligible)
            #expect(run.pauseAudio == nil)
            run.endActivity()
        }
    }

    @Test func triggerSnapshotsPreference() async {
        let f = PauseFixture()
        defer { f.cleanUp() }
        await f.start()
        f.settings.transformsOnPause = false
        await f.pause()
        f.state.cancelRequested()
    }
}

private actor PartialPauseTranscriber: Transcriber {
    let final: String
    var ready = false
    var shouldFail = false
    var offlineText = "fixture"
    var offlineCount = 0
    var offlineFrames = 0
    var offlineCancellationCount = 0
    var offlineFast = false
    var offlineLocale = ""
    var offlineVocabulary: [String] = []
    private var offlineFails = false
    private var suspended = false
    private var waiters: [Int: CheckedContinuation<String, any Error>] = [:]

    init(final: String) { self.final = final }
    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        let locale = request.locale
        let vocabulary = request.vocabulary
        let preferFastResults = request.preferFastResults
        if ready {
            offlineCount += 1
            let id = offlineCount
            offlineFast = preferFastResults
            offlineLocale = locale.identifier
            offlineVocabulary = vocabulary
            for try await buffer in audio {
                try Task.checkCancellation()
                offlineFrames += Int(buffer.frameLength)
            }
            if suspended {
                return try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    return try await withCheckedThrowingContinuation { waiters[id] = $0 }
                } onCancel: {
                    Task { await self.cancelOffline(id) }
                }
            }
            if offlineFails { throw FakeFailure.transcriber }
            return offlineText
        }
        ready = true
        for try await _ in audio {
            try Task.checkCancellation()
            if shouldFail { throw FakeFailure.transcriber }
        }
        try Task.checkCancellation()
        return final
    }
    func fail() { shouldFail = true }
    func setOfflineText(_ text: String) { offlineText = text }
    func suspendOffline() { suspended = true }
    func setOfflineFailure(_ value: Bool) { offlineFails = value }
    func completeOffline() {
        for waiter in waiters.values { waiter.resume(returning: offlineText) }
        waiters.removeAll()
    }
    private func cancelOffline(_ id: Int) {
        if let waiter = waiters.removeValue(forKey: id) {
            offlineCancellationCount += 1
            waiter.resume(throwing: CancellationError())
        }
    }
}

private actor PauseProvider: TransformerSource {
    nonisolated let permitsUnfinalizedInput: Bool
    let prepared: FakeTextTransformer
    let attempt: FakeTextTransformer
    var creationCount = 0
    init(local: Bool, prepared: FakeTextTransformer, attempt: FakeTextTransformer) {
        permitsUnfinalizedInput = local
        self.prepared = prepared
        self.attempt = attempt
    }
    func transformer(for provider: TranslationProvider, instruction: String) async -> any TextTransformer {
        creationCount += 1
        return creationCount == 1 ? prepared : attempt
    }
    @MainActor func snapshot(for provider: TranslationProvider) -> TransformerSnapshot {
        TransformerSnapshot(permitsUnfinalizedInput: permitsUnfinalizedInput) { [self] instruction in
            await transformer(for: provider, instruction: instruction)
        }
    }
}

@MainActor
private final class PauseFixture {
    let name = "SyrupPauseTests.\(UUID())"
    let settings: AppSettings
    let recorder = LevelRecorder()
    let clock = ManualRecordingClock()
    let transcriber: PartialPauseTranscriber
    let prepared = FakeTextTransformer(.success("normal"))
    let attempt: FakeTextTransformer
    let provider: PauseProvider
    let pasteboard = SpyPasteboard()
    let metrics = SpyPipelineMetrics()
    let history = HistoryStore()
    let autoPaster = SpyAutoPaster()
    let state: AppState

    init(final: String = "fixture", enabled: Bool = true, provider kind: TranslationProvider = .appleOnDevice,
         local: Bool = true, attempt: FakeTextTransformer = FakeTextTransformer(.suspended)) {
        settings = AppSettings(userDefaults: UserDefaults(suiteName: name)!, defaultMicrophoneIDProvider: { "" })
        settings.transformsOnPause = enabled
        settings.translationProvider = kind
        settings.showRecordingCue = false
        settings.showLiveTranscript = false
        settings.playSounds = false
        transcriber = PartialPauseTranscriber(final: final)
        self.attempt = attempt
        provider = PauseProvider(local: local, prepared: prepared, attempt: attempt)
        state = AppState(settings: settings, history: history, audioRecorder: recorder, transcriber: transcriber,
                         transformerProvider: provider, pasteboard: pasteboard, feedback: SpyFeedback(), metrics: metrics,
                         autoPaster: autoPaster, maximumRecordingDurationNanoseconds: 0, autoPasteDelayNanoseconds: 0, recordingClock: clock,
                         recordingCue: PauseCue(),
                         captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) })
    }
    func start() async {
        state.triggerPressed()
        await pauseWait { await self.transcriber.ready }
        recorder.yield(dBFS: -20)
        await pauseSettle()
        clock.advance(by: .seconds(1))
        recorder.yield(dBFS: -20)
        await pauseSettle()
    }
    func pause(expectAttempt: Bool = true) async {
        let before = await transcriber.offlineCount
        recorder.yield(dBFS: -60)
        await pauseSettle()
        clock.advance(by: .milliseconds(300))
        if expectAttempt {
            await pauseWait { await self.transcriber.offlineCount > before }
            await pauseWait { await self.attempt.callCount >= 1 }
            await pauseSettle()
        }
        else { await pauseSettle() }
    }
    func release() { state.triggerReleased() }
    func completed() async { await pauseWait { self.state.pipelineState == .idle } }
    func cleanUp() {
        state.cancelRequested()
        UserDefaults.standard.removePersistentDomain(forName: name)
    }
}

@MainActor private func pauseSettle() async { for _ in 0..<100 { await Task.yield() } }
@MainActor private func pauseWait(_ condition: () async -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    #expect(await condition())
}


@MainActor
private final class PauseCue: RecordingCuePresenting {
    func apply(_ state: RecordingCueState) {}
    func updateLevel(_ level: Double) {}
    func updateTranscript(_ text: String) {}
}
