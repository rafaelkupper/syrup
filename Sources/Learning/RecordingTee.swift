import AVFoundation
import Foundation

protocol RecordingFileWriting: AnyObject {
    func write(from buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: RecordingFileWriting {}

struct RecordingTeeSession: Sendable {
    let stream: AudioBufferSequence
    private let task: Task<Void, Never>

    init(stream: AudioBufferSequence, task: Task<Void, Never>) {
        self.stream = stream
        self.task = task
    }

    func waitForCompletion() async {
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelAndWait() async {
        task.cancel()
        await task.value
    }
}

enum RecordingTee {
    static func attach(
        to source: AudioBufferSequence,
        fileURL: URL,
        onOverflow: @escaping @Sendable () -> Void = {}
    ) -> RecordingTeeSession {
        attach(to: source, fileURL: fileURL, onOverflow: onOverflow) { url, format in
            try AVAudioFile(
                forWriting: url,
                settings: format.settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: format.isInterleaved
            )
        }
    }

    static func attach(
        to source: AudioBufferSequence,
        fileURL: URL,
        onOverflow: @escaping @Sendable () -> Void = {},
        makeAudioFile: @escaping @Sendable (URL, AVAudioFormat) throws -> any RecordingFileWriting
    ) -> RecordingTeeSession {
        let (stream, continuation) = AudioBufferStream.make()
        let task = Task.detached(priority: .utility) {
            var audioFile: (any RecordingFileWriting)?
            var isWritingEnabled = true

            do {
                for try await buffer in source {
                    guard AudioBufferStream.yield(buffer, to: continuation) else {
                        onOverflow()
                        break
                    }

                    guard isWritingEnabled else { continue }

                    do {
                        if audioFile == nil {
                            audioFile = try makeAudioFile(fileURL, buffer.format)
                            try FileManager.default.setAttributes(
                                [.posixPermissions: 0o600],
                                ofItemAtPath: fileURL.path(percentEncoded: false)
                            )
                        }
                        try audioFile?.write(from: buffer)
                    } catch {
                        audioFile = nil
                        isWritingEnabled = false
                        try? FileManager.default.removeItem(at: fileURL)
                    }
                }
            } catch {
                continuation.finish(throwing: error)
            }

            audioFile = nil
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return RecordingTeeSession(stream: stream, task: task)
    }
}
