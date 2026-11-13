import Foundation
import Synchronization

enum AudioFanOut {
    static func split(_ source: AudioBufferSequence) -> (AudioBufferSequence, AudioBufferSequence) {
        let first = AudioBufferStream.make()
        let second = AudioBufferStream.make()
        let task = Task.detached(priority: .userInitiated) {
            var outputs = [first.continuation, second.continuation]
            do {
                for try await buffer in source {
                    var live: [AudioBufferSequence.Continuation] = []
                    for output in outputs {
                        switch output.yield(buffer) {
                        case .enqueued:
                            live.append(output)
                        case .dropped:
                            output.finish(throwing: AudioRecordingError.audioBufferOverflow)
                        case .terminated:
                            break
                        @unknown default:
                            break
                        }
                    }
                    outputs = live
                    if outputs.isEmpty { return }
                }
                outputs.forEach { $0.finish() }
            } catch {
                outputs.forEach { $0.finish(throwing: error) }
            }
        }
        let openOutputs = Mutex(2)
        let onTermination: @Sendable (AudioBufferSequence.Continuation.Termination) -> Void = { _ in
            if openOutputs.withLock({ count in
                count -= 1
                return count == 0
            }) {
                task.cancel()
            }
        }
        first.continuation.onTermination = onTermination
        second.continuation.onTermination = onTermination
        return (first.stream, second.stream)
    }
}
