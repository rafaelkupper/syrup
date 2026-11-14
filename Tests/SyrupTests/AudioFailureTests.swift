import AVFoundation
import Foundation
import KeyboardShortcuts
import Synchronization
import Testing
@testable import Syrup

/// Capture failures: upstream errors, buffer overflow, and recognition failure stop delivery.
@MainActor
struct AudioFailureTests {
    @Test func audioStagesPreserveUpstreamFailure() async throws {
        let (source, continuation) = AudioBufferSequence.makeStream()
        let metered = AudioLevelTap.attach(to: source) { _ in }
        continuation.finish(throwing: AudioRecordingError.audioBufferOverflow)
        await #expect(throws: AudioRecordingError.audioBufferOverflow) {
            for try await _ in metered {}
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

    @Test func productionLevelTapOverflowAfterReleaseMustPreventDelivery() async throws {
        let suite = testDomainName("SyrupAudioAudit")
        let defaults = try #require(TestDefaults(suiteName: suite))
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
        let defaults = try #require(TestDefaults(suiteName: suite))
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
