import AVFoundation
import Foundation
import Testing
@testable import Syrup

@MainActor
final class FakeParakeetModels: SpeechModelProviding {
    var state: SpeechModelState
    private(set) var loadRequests = 0

    init(_ state: SpeechModelState) {
        self.state = state
    }

    func loadIfDownloaded() {
        loadRequests += 1
    }
}

actor FastResultsProbe: Transcriber {
    private(set) var requests: [Bool] = []

    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        let preferFastResults = request.preferFastResults
        requests.append(preferFastResults)
        return "apple words"
    }
}

private final class SilentCue: RecordingCuePresenting {
    func apply(_ state: RecordingCueState) {}
    func updateLevel(_ level: Double) {}
    func updateTranscript(_ text: String) {}
}

private actor PartialProbe: Transcriber {
    let text: String
    private(set) var receivedHandler: Bool?

    init(text: String) {
        self.text = text
    }

    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        let onPartialTranscript = request.onPartialTranscript
        receivedHandler = onPartialTranscript != nil
        for try await _ in audio {}
        return text
    }
}

@Suite(.serialized)
@MainActor
struct ParakeetPipelineTests {
    @Test(arguments: [(SpeechEngine.parakeetUltra, true), (.apple, false)])
    func appleRunsWithFastResultsOnlyAsAParakeetPreview(engine: SpeechEngine, fastResults: Bool) async throws {
        let apple = FastResultsProbe()
        let harness = try Harness(apple: apple, parakeet: FakeTranscriber(.success("parakeet words")), engine: engine)
        await harness.dictate()
        #expect(await apple.requests == [fastResults])
    }

    @Test func parakeetDeliversItsTranscriptWhileApplePreviews() async throws {
        let apple = FakeTranscriber(.success("apple words"))
        let harness = try Harness(apple: apple, parakeet: FakeTranscriber(.success("parakeet words")))
        await harness.dictate()
        #expect(harness.clipboard.writes == ["parakeet words"])
        #expect(await apple.callCount == 1)
        #expect(harness.feedback.errorMessages.isEmpty)
    }

    @Test(arguments: [(SpeechEngine.nemotronStreaming, false, true), (.parakeetUnifiedEN, false, true), (.parakeetUltra, true, false), (.parakeetRedux, true, false), (.canaryFlash, true, false)])
    func livePartialsComeFromStreamingModelsOrApple(engine: SpeechEngine, appleGetsPartials: Bool, modelGetsPartials: Bool) async throws {
        let apple = PartialProbe(text: "apple words"), model = PartialProbe(text: "model words")
        let harness = try Harness(apple: apple, parakeet: model, engine: engine, locale: "en-US", recordingCue: SilentCue())
        harness.state.settings.showRecordingCue = true
        harness.state.settings.showLiveTranscript = true
        await harness.dictate()
        await harness.wait { await apple.receivedHandler != nil }
        await harness.wait { await model.receivedHandler != nil }
        #expect(await apple.receivedHandler == appleGetsPartials)
        #expect(await model.receivedHandler == modelGetsPartials)
        #expect(harness.clipboard.writes == ["model words"])
    }

    @Test func aStreamingModelThatHearsNothingFallsBackToApple() async throws {
        let harness = try Harness(
            apple: PartialProbe(text: "apple words"), parakeet: PartialProbe(text: ""),
            engine: .nemotronStreaming, locale: "en-US"
        )
        await harness.dictate()
        #expect(harness.clipboard.writes == ["apple words"])
    }

    @Test func aDictationCountsItsWordsAndKeepsNoText() async throws {
        let harness = try Harness(apple: FakeTranscriber(.success("apple words")), parakeet: FakeTranscriber(.success("three parakeet words")))
        await harness.dictate()
        let stats = harness.state.usageStats.stats
        #expect(stats.totalWords == 3)
        #expect(stats.wordsByDay.values.reduce(0, +) == 3)
        let encoded = String(decoding: try JSONEncoder().encode(stats), as: UTF8.self)
        #expect(encoded.contains("parakeet") == false)
    }

    @Test func turningStatsOffCountsNothing() async throws {
        let harness = try Harness(apple: FakeTranscriber(.success("apple words")), parakeet: FakeTranscriber(.success("parakeet words")))
        harness.state.settings.keepsUsageStats = false
        await harness.dictate()
        #expect(harness.state.usageStats.stats.isEmpty)
    }

    @Test func aFailedRunCountsNothing() async throws {
        let harness = try Harness(
            apple: FakeTranscriber(.success("apple words")), parakeet: FakeTranscriber(.success("parakeet words")),
            kind: .translation(targetLanguage: "English", tonePreset: .neutral, customToneText: "")
        )
        await harness.dictate()
        #expect(harness.state.pipelineState.isError)
        #expect(harness.state.usageStats.stats.isEmpty)
    }

    @Test func appleWorkflowsNeverTouchParakeet() async throws {
        let parakeet = FakeTranscriber(.success("parakeet words"))
        let models = FakeParakeetModels(.ready)
        let harness = try Harness(apple: FakeTranscriber(.success("apple words")), parakeet: parakeet, models: models, engine: .apple)
        await harness.dictate()
        #expect(harness.clipboard.writes == ["apple words"])
        #expect(await parakeet.callCount == 0)
        #expect(models.loadRequests == 0)
    }

    @Test(arguments: [SpeechModelState.notDownloaded, .downloading(0.5), .downloaded, .loading, .failed("x"), .unsupported])
    func aModelThatIsNotReadyFallsBackToAppleWithOneNotice(state: SpeechModelState) async throws {
        let parakeet = FakeTranscriber(.success("parakeet words"))
        let models = FakeParakeetModels(state)
        let harness = try Harness(apple: FakeTranscriber(.success("apple words")), parakeet: parakeet, models: models)
        await harness.dictate()
        await harness.dictate()
        #expect(harness.clipboard.writes == ["apple words", "apple words"])
        #expect(await parakeet.callCount == 0)
        #expect(harness.feedback.errorMessages == [try #require(state.fallbackNotice(modelName: "Parakeet Ultra"))])
        #expect(models.loadRequests == 2)
    }

    @Test func aParakeetFailureFallsBackToApplesTranscript() async throws {
        let harness = try Harness(apple: FakeTranscriber(.success("apple words")), parakeet: FakeTranscriber(.failure(.transcriber)))
        await harness.dictate()
        #expect(harness.clipboard.writes == ["apple words"])
    }

    @Test func anEmptyParakeetTranscriptDeliversApplesText() async throws {
        let harness = try Harness(apple: FakeTranscriber(.success("apple words")), parakeet: FakeTranscriber(.success(" ")))
        await harness.dictate()
        #expect(harness.clipboard.writes == ["apple words"])
    }

    @Test(arguments: [FakeTranscriber.Behavior.success(""), .failure(.languageModelInstalling)])
    func parakeetHearingNothingWithoutAppleTextEndsAsNothingHeard(apple: FakeTranscriber.Behavior) async throws {
        let harness = try Harness(apple: FakeTranscriber(apple), parakeet: FakeTranscriber(.success("")))
        await harness.dictate()
        #expect(harness.state.pipelineState == .error(userMessage(for: PipelineError.emptyTranscript)))
        #expect(harness.clipboard.writes.isEmpty)
        #expect(harness.state.history.records.isEmpty)
    }

    @Test func missingAppleAssetsOnlyTurnOffThePreview() async throws {
        let harness = try Harness(apple: FakeTranscriber(.failure(.languageModelInstalling)), parakeet: FakeTranscriber(.success("parakeet words")))
        await harness.dictate()
        #expect(harness.clipboard.writes == ["parakeet words"])
    }

    @Test func bothEnginesFailingShowsTheTypedTranscriptionError() async throws {
        let harness = try Harness(apple: FakeTranscriber(.failure(.languageModelInstalling)), parakeet: FakeTranscriber(.failure(.transcriber)))
        await harness.dictate()
        #expect(harness.clipboard.writes.isEmpty)
        #expect(harness.state.pipelineState == .error(userMessage(for: TranscriptionError.languageModelInstalling("Portuguese (Brazil)"))))
    }

    @Test func bothEnginesFailingWhileRecordingStopsCaptureWithApplesError() async throws {
        let apple = FakeTranscriber(.failure(.languageModelInstalling))
        let parakeet = FakeTranscriber(.failure(.transcriber))
        let harness = try Harness(apple: apple, parakeet: parakeet)
        let message = userMessage(for: TranscriptionError.languageModelInstalling("Portuguese (Brazil)"))
        harness.state.triggerPressed()
        await apple.waitForCall()
        await parakeet.waitForCall()
        await harness.settle(until: .error(message))
        #expect(harness.recorder.stopCallCount > 0)
        #expect(harness.feedback.errorMessages == [message])
        #expect(harness.clipboard.writes.isEmpty)
    }

    @Test func cancelStopsBothEnginesAndWritesNothing() async throws {
        let apple = FakeTranscriber(.suspended)
        let parakeet = FakeTranscriber(.suspended)
        let harness = try Harness(apple: apple, parakeet: parakeet)
        harness.state.triggerPressed()
        await parakeet.waitForCall()
        await apple.waitForCall()
        harness.state.triggerReleased()
        await harness.settle(until: .transcribing)
        harness.state.cancelRequested()
        await parakeet.waitForCancellation()
        await apple.waitForCancellation()
        #expect(harness.state.pipelineState == .idle)
        #expect(harness.clipboard.writes.isEmpty)
        #expect(harness.state.history.records.isEmpty)
    }

    @Test(arguments: [false, true])
    func cancelWhileFallingBackToAppleStopsAppleAndDiscardsTheRecording(learning: Bool) async throws {
        let apple = FakeTranscriber(.suspended)
        let parakeet = FakeTranscriber(.suspended)
        let archive = learning ? SpyRecordingArchive() : nil
        let harness = try Harness(apple: apple, parakeet: parakeet, archive: archive)
        harness.state.triggerPressed()
        await apple.waitForCall()
        await parakeet.waitForCall()
        harness.state.triggerReleased()
        await harness.settle(until: .transcribing)
        await parakeet.fail(.transcriber)
        await harness.wait { await parakeet.finishedCount == 1 }

        harness.state.cancelRequested()
        await harness.wait { await apple.cancellationCount == 1 }
        #expect(await apple.cancellationCount == 1)
        if let archive {
            await harness.wait { await archive.snapshot().discardedEntryIDs.count == 1 }
            let snapshot = await archive.snapshot()
            #expect(snapshot.begunEntryIDs.count == 1)
            #expect(snapshot.discardedEntryIDs == snapshot.begunEntryIDs)
            for id in snapshot.begunEntryIDs {
                try? FileManager.default.removeItem(at: await archive.audioFileURL(id: id))
            }
        }
        #expect(harness.state.pipelineState == .idle)
        #expect(harness.clipboard.writes.isEmpty)
        #expect(harness.state.history.records.isEmpty)
    }

    @Test func aShortTapWithAModelThatIsNotReadyStaysSilent() async throws {
        let apple = FakeTranscriber(.suspended)
        let clock = ManualRecordingClock()
        let harness = try Harness(apple: apple, parakeet: FakeTranscriber(.success("parakeet words")),
                                  models: FakeParakeetModels(.loading), clock: clock)
        harness.state.triggerPressed()
        await apple.waitForCall()
        clock.advance(by: .milliseconds(100))
        harness.state.triggerReleased()
        await apple.waitForCancellation()
        #expect(harness.state.pipelineState == .idle)
        #expect(harness.feedback.errorMessages.isEmpty)
        #expect(harness.clipboard.writes.isEmpty)
    }

    @Test(arguments: [true, false])
    func learningArchivesOnlyApplesTranscript(appleSucceeds: Bool) async throws {
        let archive = SpyRecordingArchive()
        let apple = FakeTranscriber(appleSucceeds ? .success("apple words") : .failure(.transcriber))
        let harness = try Harness(apple: apple, parakeet: FakeTranscriber(.success("parakeet words")), archive: archive)
        await harness.dictate()
        for _ in 0..<1000 {
            let snapshot = await archive.snapshot()
            if snapshot.commits.count + snapshot.discardedEntryIDs.count == 1 { break }
            await Task.yield()
        }
        let snapshot = await archive.snapshot()
        #expect(harness.clipboard.writes == ["parakeet words"])
        #expect(snapshot.commits.map(\.appleTranscript) == (appleSucceeds ? ["apple words"] : []))
        #expect(snapshot.discardedEntryIDs.count == (appleSucceeds ? 0 : 1))
    }

    @Test func fanOutKeepsFeedingOneOutputAfterTheOtherConsumerIsCancelled() async throws {
        let source = AudioBufferStream.make()
        let (first, second) = AudioFanOut.split(source.stream)
        let cancelled = Task { for try await _ in first {} }
        cancelled.cancel()
        _ = await cancelled.result
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        for frames in 1...3 {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
            buffer.frameLength = AVAudioFrameCount(frames)
            _ = source.continuation.yield(buffer)
        }
        source.continuation.finish()
        var lengths: [AVAudioFrameCount] = []
        for try await buffer in second {
            lengths.append(buffer.frameLength)
        }
        #expect(lengths == [1, 2, 3])
    }

    @Test func fanOutForwardsASourceErrorToBothOutputs() async throws {
        let source = AudioBufferStream.make()
        let (first, second) = AudioFanOut.split(source.stream)
        source.continuation.finish(throwing: AudioRecordingError.audioBufferOverflow)
        for output in [first, second] {
            await #expect(throws: AudioRecordingError.audioBufferOverflow) {
                for try await _ in output {}
            }
        }
    }
}

@MainActor
private final class Harness {
    let state: AppState
    let recorder = FakeRecorder()
    let clipboard: SpyPasteboard
    let feedback: SpyFeedback
    private let suiteName: String

    init(
        apple: any Transcriber,
        parakeet: any Transcriber,
        kind: WorkflowKind = .transcribeOnly(cleanup: false),
        models: FakeParakeetModels = FakeParakeetModels(.ready),
        engine: SpeechEngine = .parakeetUltra,
        locale: String = "pt-BR",
        archive: SpyRecordingArchive? = nil,
        clock: any RecordingClock = FastForwardClock(),
        recordingCue: (any RecordingCuePresenting)? = nil
    ) throws {
        let suiteName = testDomainName("ParakeetPipelineTests")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let clipboard = SpyPasteboard(), feedback = SpyFeedback()
        self.suiteName = suiteName
        self.clipboard = clipboard
        self.feedback = feedback
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.glossaryLearningEnabled = archive != nil
        settings.workflowList = WorkflowList(workflows: [Workflow(
            id: UUID(), name: "Dictate", kind: kind, dictationLocaleID: locale,
            translationProvider: nil, speechEngine: engine
        )])
        state = AppState.fixture(
            settings: settings, audioRecorder: recorder, transcriber: apple, speechModels: [engine == .apple ? .parakeetUltra : engine: InstalledSpeechModel(transcriber: parakeet, models: models)],
            transformer: FakeTextTransformer(.failure(.transformer)), pasteboard: clipboard,
            feedback: feedback, maximumRecordingDurationNanoseconds: 0, recordingClock: clock, recordingCue: recordingCue,
            recordingArchive: archive
        )
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    func dictate() async {
        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await eventually("Pipeline did not finish") { state.pipelineState == .idle || state.pipelineState.isError }
    }

    func settle(until expected: AppState.PipelineState) async {
        await eventually { state.pipelineState == expected }
        #expect(state.pipelineState == expected)
    }

    func wait(until condition: () async -> Bool) async {
        await eventually { await condition() }
    }
}
