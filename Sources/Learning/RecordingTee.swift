import AVFoundation
import Foundation
import Synchronization

protocol RecordingFileWriting: AnyObject {
    func write(from buffer: AVAudioPCMBuffer) throws
}

extension AVAudioFile: RecordingFileWriting {}

struct RecordingTeeSession: Sendable {
    let stream: AudioBufferSequence
    private let forwarder: Task<Void, Never>
    private let writer: Task<Bool, Never>

    init(stream: AudioBufferSequence, forwarder: Task<Void, Never>, writer: Task<Bool, Never>) {
        self.stream = stream
        self.forwarder = forwarder
        self.writer = writer
    }

    /// Waits for forwarding and the archive write to finish. Returns true when the WAV file holds
    /// every forwarded buffer; false when archiving was abandoned and the file removed.
    @discardableResult
    func waitForCompletion() async -> Bool {
        await withTaskCancellationHandler {
            await forwarder.value
            return await writer.value
        } onCancel: {
            forwarder.cancel()
            writer.cancel()
        }
    }

    func cancelAndWait() async {
        forwarder.cancel()
        writer.cancel()
        await forwarder.value
        _ = await writer.value
    }
}

/// Forwards live audio to the transcriber and copies it to a WAV file for glossary learning.
/// Forwarding never waits on the disk: the file is written by a separate utility-priority consumer,
/// and if that consumer falls behind, archiving stops for the run instead of delaying or failing it.
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
        writeCapacity: Int = AudioBufferStream.capacity,
        makeAudioFile: @escaping @Sendable (URL, AVAudioFormat) throws -> any RecordingFileWriting
    ) -> RecordingTeeSession {
        let (stream, continuation) = AudioBufferStream.make()
        let (writes, writeContinuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, writeCapacity))
        )
        let abandoned = ArchiveAbandonment()

        let writer = Task.detached(priority: .utility) { () -> Bool in
            var audioFile: (any RecordingFileWriting)?
            var isWritingEnabled = true
            for await buffer in writes {
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
                    isWritingEnabled = false
                }
            }
            audioFile = nil
            if isWritingEnabled == false || abandoned.isAbandoned {
                try? FileManager.default.removeItem(at: fileURL)
                return false
            }
            return Task.isCancelled == false
        }

        let forwarder = Task.detached(priority: .userInitiated) {
            var isArchiving = true
            do {
                for try await buffer in source {
                    guard AudioBufferStream.yield(buffer, to: continuation) else {
                        onOverflow()
                        break
                    }
                    if isArchiving, case .dropped = writeContinuation.yield(buffer) {
                        isArchiving = false
                        abandoned.abandon()
                        writeContinuation.finish()
                    }
                }
            } catch {
                continuation.finish(throwing: error)
            }

            writeContinuation.finish()
            continuation.finish()
        }
        continuation.onTermination = { _ in
            forwarder.cancel()
        }
        return RecordingTeeSession(stream: stream, forwarder: forwarder, writer: writer)
    }
}

private final class ArchiveAbandonment: Sendable {
    private let flag = Mutex(false)
    var isAbandoned: Bool { flag.withLock { $0 } }
    func abandon() { flag.withLock { $0 = true } }
}
