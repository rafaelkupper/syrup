import AVFoundation
import Foundation
import Testing
@testable import Syrup

// MARK: - LevelSmoother

struct LevelSmootherTests {
    @Test
    func silenceStaysAtZero() {
        var smoother = LevelSmoother()

        for _ in 0..<10 {
            #expect(smoother.process(rms: 0) == 0)
        }
    }

    @Test
    func loudInputApproachesFullLevel() {
        var smoother = LevelSmoother()
        var level = 0.0

        // 0.4 RMS is about -8 dB, the normalization ceiling.
        for _ in 0..<20 {
            level = smoother.process(rms: 0.4)
        }

        #expect(level > 0.95)
    }

    @Test
    func attackIsFasterThanRelease() {
        var rising = LevelSmoother()
        let riseStep = rising.process(rms: 0.4)

        var falling = LevelSmoother()
        var level = 0.0
        for _ in 0..<20 {
            level = falling.process(rms: 0.4)
        }
        let fallStep = level - falling.process(rms: 0)

        #expect(riseStep > fallStep)
    }

    @Test
    func normalizationClampsToUnitRange() {
        let quiet = LevelSmoother.normalizedLevel(
            rms: 0.0001,
            floorDecibels: -50,
            ceilingDecibels: -8
        )
        let loud = LevelSmoother.normalizedLevel(
            rms: 1.0,
            floorDecibels: -50,
            ceilingDecibels: -8
        )
        let middle = LevelSmoother.normalizedLevel(
            rms: 0.035,
            floorDecibels: -50,
            ceilingDecibels: -8
        )

        #expect(quiet == 0)
        #expect(loud == 1)
        #expect(middle > 0.4 && middle < 0.8)
    }
}

// MARK: - Buffer RMS

struct AudioBufferRMSTests {
    @Test
    func constantSignalReportsItsAmplitude() throws {
        let buffer = try makeConstantBuffer(sampleValue: 0.5, frameCount: 512)

        let rms = try #require(buffer.rmsLevel)
        #expect(abs(rms - 0.5) < 0.0001)
    }

    @Test
    func emptyBufferReportsNoLevel() throws {
        let buffer = try makeConstantBuffer(sampleValue: 0, frameCount: 0)

        #expect(buffer.rmsLevel == nil)
    }
}

// MARK: - AudioLevelTap

struct AudioLevelTapTests {
    @Test
    func forwardsEveryBufferAndReportsLevels() async throws {
        let (source, continuation) = AudioBufferSequence.makeStream()
        let levels = LevelSink()

        let tapped = AudioLevelTap.attach(to: source) { level in
            levels.append(level.smoothed)
        }

        let bufferCount = 3
        for _ in 0..<bufferCount {
            continuation.yield(try makeConstantBuffer(sampleValue: 0.25, frameCount: 256))
        }
        continuation.finish()

        var forwarded = 0
        for try await buffer in tapped {
            #expect(buffer.frameLength == 256)
            forwarded += 1
        }

        #expect(forwarded == bufferCount)
        #expect(levels.values.count == bufferCount)
        #expect(levels.values.allSatisfy { $0 > 0 })
    }
}

// MARK: - TranscriptTypewriter

struct TranscriptTypewriterTests {
    @Test
    func typesTowardTargetProgressively() {
        var typewriter = TranscriptTypewriter()
        typewriter.target = "hello world, this is a longer sentence"

        var previousCount = 0
        var steps = 0
        while typewriter.advance() {
            #expect(typewriter.displayed.count > previousCount)
            #expect(typewriter.target.hasPrefix(typewriter.displayed))
            previousCount = typewriter.displayed.count
            steps += 1
            #expect(steps < 100)
        }

        #expect(typewriter.displayed == typewriter.target)
        #expect(steps > 1)
    }

    @Test
    func rewrittenTargetSnapsToCommonPrefixThenRetypes() {
        var typewriter = TranscriptTypewriter()
        typewriter.target = "hello world"
        while typewriter.advance() {}
        #expect(typewriter.displayed == "hello world")

        typewriter.target = "hello there, friend"
        let snapped = typewriter.advance()
        #expect(snapped)
        #expect(typewriter.displayed == "hello ")

        while typewriter.advance() {}
        #expect(typewriter.displayed == "hello there, friend")
    }

    @Test
    func caughtUpTypewriterReportsNoWork() {
        var typewriter = TranscriptTypewriter()
        let idleAdvance = typewriter.advance()
        #expect(idleAdvance == false)

        typewriter.target = "hi"
        while typewriter.advance() {}
        let caughtUpAdvance = typewriter.advance()
        #expect(caughtUpAdvance == false)
    }

    @Test
    func resetClearsDisplayedAndTarget() {
        var typewriter = TranscriptTypewriter()
        typewriter.target = "hello"
        while typewriter.advance() {}

        typewriter.reset()

        #expect(typewriter.displayed.isEmpty)
        #expect(typewriter.target.isEmpty)
        let advanceAfterReset = typewriter.advance()
        #expect(advanceAfterReset == false)
    }
}

// MARK: - AppState presentation

@MainActor
struct RecordingCuePresentationTests {
    @Test
    func cueMirrorsSuccessfulRunLifecycle() async {
        let cue = SpyRecordingCue()
        let state = makeCueState(recordingCue: cue)

        state.triggerPressed()
        await waitFor { cue.states.first == .recording(caption: nil) }

        state.triggerReleased()
        await waitFor { state.pipelineState == .idle && cue.states.last == .hidden }

        #expect(cue.states.first == .recording(caption: nil))
        #expect(cue.states.contains(.processing))
        #expect(cue.states.contains(.success))
        #expect(cue.states.last == .hidden)
    }

    @Test
    func cueReceivesPartialTranscripts() async {
        let cue = SpyRecordingCue()
        let state = makeCueState(recordingCue: cue)

        state.triggerPressed()
        state.triggerReleased()
        await waitFor { cue.transcripts.isEmpty == false }

        #expect(cue.transcripts.contains("bom dia, tudo bem?"))
    }

    @Test
    func cueHidesOnCancelWithoutSuccessFlash() async {
        let cue = SpyRecordingCue()
        let state = makeCueState(recordingCue: cue)

        state.triggerPressed()
        await waitFor { cue.states.first == .recording(caption: nil) }

        state.cancelRequested()
        await waitFor { state.pipelineState == .idle }

        #expect(cue.states.last == .hidden)
        #expect(cue.states.contains(.success) == false)
    }

    @Test
    func failedRunShowsErrorStateThenHides() async {
        let cue = SpyRecordingCue()
        let state = makeCueState(
            recordingCue: cue,
            transcriber: FakeTranscriber(.failure(.transcriber))
        )

        state.triggerPressed()
        await waitFor { cue.states.first == .recording(caption: nil) }

        state.triggerReleased()
        await waitFor { state.pipelineState == .idle && cue.states.last == .hidden }

        let sawError = cue.states.contains { state in
            if case .error = state { return true }
            return false
        }
        #expect(sawError)
        #expect(cue.states.contains(.success) == false)
        #expect(cue.states.last == .hidden)
    }

    @Test
    func disabledCueSettingKeepsCueHiddenThroughRun() async {
        let cue = SpyRecordingCue()
        let settings = makeCueTestSettings()
        settings.showRecordingCue = false
        let state = makeCueState(recordingCue: cue, settings: settings)

        state.triggerPressed()
        state.triggerReleased()
        await waitFor { state.pipelineState == .idle }

        #expect(cue.states.isEmpty)
        #expect(cue.transcripts.isEmpty)
        #expect(cue.levels.isEmpty)
    }

    @Test
    func disabledLiveTranscriptKeepsCueButSkipsPartials() async {
        let cue = SpyRecordingCue()
        let settings = makeCueTestSettings()
        settings.showLiveTranscript = false
        let state = makeCueState(recordingCue: cue, settings: settings)

        state.triggerPressed()
        await waitFor { cue.states.first == .recording(caption: nil) }

        state.triggerReleased()
        await waitFor { state.pipelineState == .idle && cue.states.last == .hidden }

        #expect(cue.states.contains(.success))
        #expect(cue.transcripts.isEmpty)
    }

    @Test
    func revisionRunShowsRevisionCaption() async {
        let cue = SpyRecordingCue()
        let history = HistoryStore()
        history.append(DictationRecord(
            id: UUID(),
            finishedAt: Date.now,
            transcript: "original dictation",
            output: "previous output",
            transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: .success
        ))
        let state = makeCueState(recordingCue: cue, history: history)

        state.startRevision()
        await waitFor { cue.states.isEmpty == false }

        #expect(cue.states.first == .recording(caption: "Revising last result"))
    }
}

// MARK: - Helpers

private func makeConstantBuffer(
    sampleValue: Float,
    frameCount: AVAudioFrameCount
) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: true
    ))
    let buffer = try #require(AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: max(frameCount, 1)
    ))
    buffer.frameLength = frameCount
    if frameCount > 0, let channelData = buffer.floatChannelData {
        for frame in 0..<Int(frameCount) {
            channelData[0][frame] = sampleValue
        }
    }
    return buffer
}

private final class LevelSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ level: Double) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(level)
    }
}

@MainActor
private final class SpyRecordingCue: RecordingCuePresenting {
    private(set) var states: [RecordingCueState] = []
    private(set) var levels: [Double] = []
    private(set) var transcripts: [String] = []

    func apply(_ state: RecordingCueState) {
        guard state != states.last else { return }
        // Idle housekeeping before a run starts re-applies .hidden; only the
        // states from the first visible one onward are interesting.
        if states.isEmpty, state == .hidden { return }
        states.append(state)
    }

    func updateLevel(_ level: Double) {
        levels.append(level)
    }

    func updateTranscript(_ text: String) {
        transcripts.append(text)
    }
}

@MainActor
private func makeCueState(
    recordingCue: SpyRecordingCue,
    transcriber: any Transcriber = FakeTranscriber(.success("bom dia, tudo bem?")),
    history: HistoryStore = HistoryStore(),
    settings: AppSettings? = nil
) -> AppState {
    AppState.fixture(
        settings: settings ?? makeCueTestSettings(),
        history: history,
        audioRecorder: FakeRecorder(),
        transcriber: transcriber,
        transformer: FakeTextTransformer(.success("Good morning, how are you?")),
        pasteboard: SpyPasteboard(),
        feedback: SpyFeedback(),
        autoPaster: SpyAutoPaster(),
        errorResetDelayNanoseconds: 0,
        feedbackFlashDurationNanoseconds: 0,
        recordingClock: FastForwardClock(),
        selectionReader: FakeSelectionReader(.empty),
        recordingCue: recordingCue
    )
}

@MainActor
private func makeCueTestSettings() -> AppSettings {
    let suiteName = testDomainName("SyrupRecordingCueTests")
    guard let userDefaults = TestDefaults(suiteName: suiteName) else {
        preconditionFailure("Unable to create isolated recording-cue test defaults")
    }
    userDefaults.removePersistentDomain(forName: suiteName)
    return AppSettings(
        userDefaults: userDefaults,
        defaultMicrophoneIDProvider: { "" }
    )
}

@MainActor
private func waitFor(
    _ condition: () -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    await eventually(sourceLocation: sourceLocation, condition)
    #expect(condition(), sourceLocation: sourceLocation)
}
