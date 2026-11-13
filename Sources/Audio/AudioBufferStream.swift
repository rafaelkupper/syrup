import AVFoundation

typealias AudioBufferSequence = AsyncThrowingStream<AVAudioPCMBuffer, any Error>

/// A bounded handoff. Overflow must fail the run; dropping speech silently is unsafe.
enum AudioBufferStream {
    static let capacity = 256

    static func make() -> (stream: AudioBufferSequence, continuation: AudioBufferSequence.Continuation) {
        AudioBufferSequence.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }

    static func yield(_ buffer: AVAudioPCMBuffer, to continuation: AudioBufferSequence.Continuation) -> Bool {
        if case .dropped = continuation.yield(buffer) {
            continuation.finish(throwing: AudioRecordingError.audioBufferOverflow)
            return false
        }
        return true
    }
}
