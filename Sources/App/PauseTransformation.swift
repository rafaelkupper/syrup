import AVFoundation
import Foundation
import os

enum PauseTransformation {
    static let quietDuration: Duration = .milliseconds(300)

    static func sameInput(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func input(_ transcript: String, corrections: [Correction]) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return corrections.isEmpty ? trimmed
            : Correction.apply(corrections, to: trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
final class PauseTransformationAttempt {
    let input: String
    struct Output: Sendable {
        let text: String
        let duration: Duration
    }

    let task: Task<Output?, Never>

    init(input: String, instruction: String, provider: TranslationProvider,
         snapshot: TransformerSnapshot, clock: any RecordingClock) {
        self.input = input
        task = Task {
            let transformer = await snapshot.transformer(instruction: instruction)
            do {
                try Task.checkCancellation()
                let startedAt = clock.now
                let output = try await transformer.transform(input, instruction: instruction)
                try Task.checkCancellation()
                return Output(text: output, duration: startedAt.duration(to: clock.now))
            } catch {
                return nil
            }
        }
    }
}

/// Copies a run's audio for the offline pass. Buffers pass through it on the audio path, so it is
/// lock-protected and nonisolated: the live transcriber must never wait for the main actor.
final class PauseAudioCapture: @unchecked Sendable {
    static let maximumSeconds = 90.0
    private struct State {
        var buffers: [AVAudioPCMBuffer] = []
        var frameCount = 0
        var isCapturing = true
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var frameCount: Int { state.withLock { $0.frameCount } }
    var isCapturing: Bool { state.withLock { $0.isCapturing } }

    /// Returns true when this buffer ended capture (a format change or the cap).
    @discardableResult
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard buffer.frameLength > 0, isCapturing else { return false }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return stopIfCapturing()
        }
        copy.frameLength = buffer.frameLength
        Self.copy(buffer, into: copy, at: 0)
        return state.withLock { state in
            guard state.isCapturing else { return false }
            guard state.buffers.first.map({ $0.format == buffer.format }) ?? true,
                  Double(state.frameCount + Int(buffer.frameLength)) <= buffer.format.sampleRate * Self.maximumSeconds else {
                state = State(isCapturing: false)
                return true
            }
            state.buffers.append(copy)
            state.frameCount += Int(copy.frameLength)
            return false
        }
    }

    func snapshot() -> AudioBufferSequence? {
        let (buffers, frameCount) = state.withLock { state -> ([AVAudioPCMBuffer], Int) in
            state.isCapturing ? (state.buffers, state.frameCount) : ([], 0)
        }
        guard let first = buffers.first,
              let snapshot = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(frameCount)) else { return nil }
        snapshot.frameLength = AVAudioFrameCount(frameCount)
        var offset = 0
        for buffer in buffers {
            Self.copy(buffer, into: snapshot, at: offset)
            offset += Int(buffer.frameLength)
        }
        // One coalesced buffer keeps the offline feed within the analyzer's bounded queue.
        let (stream, continuation) = AudioBufferSequence.makeStream(bufferingPolicy: .bufferingOldest(1))
        continuation.yield(snapshot)
        continuation.finish()
        return stream
    }

    func stop() {
        state.withLock { $0 = State(isCapturing: false) }
    }

    private func stopIfCapturing() -> Bool {
        state.withLock { state in
            guard state.isCapturing else { return false }
            state = State(isCapturing: false)
            return true
        }
    }

    func attach(to source: AudioBufferSequence,
                onLimit: @escaping @MainActor @Sendable () -> Void) -> AudioBufferSequence {
        let (stream, continuation) = AudioBufferStream.make()
        let task = Task { [self] in
            do {
                for try await buffer in source {
                    try Task.checkCancellation()
                    if append(buffer) { Task { @MainActor in onLimit() } }
                    guard AudioBufferStream.yield(buffer, to: continuation) else { break }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer, at frameOffset: Int) {
        let origin = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        let stride = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        for channel in 0..<min(origin.count, target.count) {
            guard let destination = target[channel].mData, let samples = origin[channel].mData else { continue }
            destination.advanced(by: frameOffset * stride).copyMemory(
                from: samples, byteCount: Int(source.frameLength) * stride)
        }
    }
}
