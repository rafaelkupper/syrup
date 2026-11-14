import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Syrup

@MainActor
struct RecordingArchiveTests {
    @Test
    func beginAndCommitCreateProtectedAudioAndSidecarFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let id = UUID()

        let audioURL = try await archive.beginEntry(id: id)
        await archive.commitEntry(
            id: id,
            localeID: "pt-BR",
            appleTranscript: "deploy concluído"
        )

        let sidecarURL = directory.appending(path: "\(id.uuidString).json")
        #expect(FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path(percentEncoded: false)))
        #expect(try permissions(at: directory) == 0o700)
        #expect(try permissions(at: audioURL) == 0o600)
        #expect(try permissions(at: sidecarURL) == 0o600)

        let data = try Data(contentsOf: sidecarURL)
        let sidecar = try JSONDecoder().decode(RecordingSidecar.self, from: data)
        #expect(sidecar.id == id)
        #expect(sidecar.localeID == "pt-BR")
        #expect(sidecar.appleTranscript == "deploy concluído")
        #expect(sidecar.attempts == 0)
    }

    @Test
    func beginFailureRemovesTheUnprotectedPlaceholder() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(
            storageDirectory: directory,
            fileManager: FailingFilePermissionManager()
        )
        let id = UUID()
        let audioURL = directory.appending(path: "\(id.uuidString).wav")

        await #expect(throws: RecordingArchiveError.beginFailed(code: 513)) {
            try await archive.beginEntry(id: id)
        }
        #expect(FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) == false)
    }

    @Test
    func discardRemovesAudioAndSidecarFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let id = UUID()
        let audioURL = try await archive.beginEntry(id: id)
        await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "deploy")
        let sidecarURL = directory.appending(path: "\(id.uuidString).json")

        await archive.discardEntry(id: id)

        #expect(FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) == false)
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path(percentEncoded: false)) == false)
        #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) == false)
    }

    @Test
    func deniedDiscardIsReportedRetriedAndBlocksNewEntries() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let deletion = DeletionGate()
        let archive = RecordingArchive(storageDirectory: directory, fileManager: DeletionDenyingFileManager(gate: deletion))
        let id = UUID()
        let audioURL = try await archive.beginEntry(id: id)

        deletion.deniesDeletion = true
        #expect(await archive.discardEntry(id: id) == false)
        #expect(FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)))
        #expect(await archive.unresolvedDeletions() == [id])
        await #expect(throws: RecordingArchiveError.cleanupPending) {
            try await archive.beginEntry(id: UUID())
        }

        deletion.deniesDeletion = false
        #expect(await archive.unresolvedDeletions().isEmpty)
        #expect(FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) == false)
        _ = try await archive.beginEntry(id: UUID())
    }

    @Test
    func entriesThatCannotBeDeletedNeverExceedTheCapOrReachAnalysis() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let deletion = DeletionGate()
        let archive = RecordingArchive(
            maxEntries: 1,
            storageDirectory: directory,
            fileManager: DeletionDenyingFileManager(gate: deletion),
            now: { clock.now }
        )
        let older = UUID()
        let newer = UUID()
        _ = try await archive.beginEntry(id: older)
        await archive.commitEntry(id: older, localeID: "pt-BR", appleTranscript: "deploy")
        clock.advance(by: 1)
        _ = try await archive.beginEntry(id: newer)

        deletion.deniesDeletion = true
        await archive.commitEntry(id: newer, localeID: "pt-BR", appleTranscript: "deploy")

        #expect(await archive.pendingEntries().map(\.id) == [newer])
        #expect(entryExists(id: older, in: directory))
        #expect(await archive.unresolvedDeletions() == [older])

        deletion.deniesDeletion = false
        #expect(await archive.pendingEntries().map(\.id) == [newer])
        #expect(entryExists(id: older, in: directory) == false)
    }

    @Test
    func deleteEntryRemovesAudioAndSidecarFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let id = UUID()
        let audioURL = try await archive.beginEntry(id: id)
        await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "deploy")
        let sidecarURL = directory.appending(path: "\(id.uuidString).json")

        await archive.deleteEntry(id: id)

        #expect(FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false)) == false)
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path(percentEncoded: false)) == false)
    }

    @Test
    func entryCapDeletesTheOldestPairs() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let archive = RecordingArchive(
            maxEntries: 2,
            storageDirectory: directory,
            now: { clock.now }
        )
        let ids = [UUID(), UUID(), UUID()]

        for id in ids {
            _ = try await archive.beginEntry(id: id)
            await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "deploy")
            clock.advance(by: 1)
        }

        #expect(await archive.pendingEntries().map(\.id) == Array(ids.suffix(2)))
        #expect(entryExists(id: ids[0], in: directory) == false)
        #expect(entryExists(id: ids[1], in: directory))
        #expect(entryExists(id: ids[2], in: directory))
    }

    @Test
    func ageCapDeletesExpiredPairsOnTheNextCommit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let archive = RecordingArchive(
            maxAge: 10,
            storageDirectory: directory,
            now: { clock.now }
        )
        let expiredID = UUID()
        _ = try await archive.beginEntry(id: expiredID)
        await archive.commitEntry(id: expiredID, localeID: "pt-BR", appleTranscript: "deploy")

        clock.advance(by: 11)
        let currentID = UUID()
        _ = try await archive.beginEntry(id: currentID)
        await archive.commitEntry(id: currentID, localeID: "pt-BR", appleTranscript: "commit")

        #expect(await archive.pendingEntries().map(\.id) == [currentID])
        #expect(entryExists(id: expiredID, in: directory) == false)
        #expect(entryExists(id: currentID, in: directory))
    }

    @Test
    func pendingEntriesPrunesExpiredPairsWithoutANewCommit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let archive = RecordingArchive(
            maxAge: 10,
            storageDirectory: directory,
            now: { clock.now }
        )
        let id = UUID()
        _ = try await archive.beginEntry(id: id)
        await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "deploy")

        clock.advance(by: 11)

        #expect(await archive.pendingEntries().isEmpty)
        #expect(entryExists(id: id, in: directory) == false)
    }

    @Test
    func pendingEntriesAreSortedOldestFirst() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_000))
        let archive = RecordingArchive(
            storageDirectory: directory,
            now: { clock.now }
        )
        let ids = [UUID(), UUID(), UUID()]

        for id in ids.reversed() {
            _ = try await archive.beginEntry(id: id)
            await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "deploy")
            clock.advance(by: -1)
        }

        #expect(await archive.pendingEntries().map(\.id) == ids)
    }

    @Test
    func recordAttemptIncrementsAndPersistsTheSidecarCount() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let id = UUID()
        _ = try await archive.beginEntry(id: id)
        await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "deploy")

        #expect(await archive.recordAttempt(id: id) == 1)
        #expect(await archive.recordAttempt(id: id) == 2)

        let sidecar = try #require(await archive.pendingEntries().first)
        #expect(sidecar.attempts == 2)
        let sidecarURL = directory.appending(path: "\(id.uuidString).json")
        #expect(try permissions(at: sidecarURL) == 0o600)
    }

    @Test
    func nextCommitDeletesOrphanedAndCorruptArtifacts() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let orphanID = UUID()
        _ = try await archive.beginEntry(id: orphanID)
        let corruptID = UUID()
        _ = try await archive.beginEntry(id: corruptID)
        await archive.commitEntry(id: corruptID, localeID: "pt-BR", appleTranscript: "deploy")
        let corruptSidecarURL = directory.appending(path: "\(corruptID.uuidString).json")
        try Data("not json".utf8).write(to: corruptSidecarURL, options: .atomic)

        let validID = UUID()
        _ = try await archive.beginEntry(id: validID)
        await archive.commitEntry(id: validID, localeID: "pt-BR", appleTranscript: "commit")

        #expect(entryExists(id: orphanID, in: directory) == false)
        #expect(entryExists(id: corruptID, in: directory) == false)
        #expect(entryExists(id: validID, in: directory))
        #expect(await archive.pendingEntries().map(\.id) == [validID])
    }

    @Test
    func deleteAllRemovesTheRecordingDirectory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let id = UUID()
        _ = try await archive.beginEntry(id: id)
        await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "deploy")

        try await archive.deleteAll()

        #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) == false)
    }

    @Test
    func teeForwardsEveryBufferAndWritesReadableWAV() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appending(path: "recording.wav")
        let (source, continuation) = AudioBufferSequence.makeStream()
        let tee = RecordingTee.attach(to: source, fileURL: fileURL)

        for _ in 0..<3 {
            continuation.yield(try constantBuffer(sampleValue: 0.25, frameCount: 256))
        }
        continuation.finish()

        var forwardedFrameLengths: [AVAudioFrameCount] = []
        for try await buffer in tee.stream {
            forwardedFrameLengths.append(buffer.frameLength)
        }
        #expect(await tee.waitForCompletion())
        let audioFile = try AVAudioFile(forReading: fileURL)

        #expect(forwardedFrameLengths == [256, 256, 256])
        #expect(audioFile.length == 3 * 256)
        #expect(try permissions(at: fileURL) == 0o600)
    }

    @Test
    func teeKeepsForwardingAfterTheWriterCannotOpen() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory
            .appending(path: "missing", directoryHint: .isDirectory)
            .appending(path: "recording.wav")
        let (source, continuation) = AudioBufferSequence.makeStream()
        let tee = RecordingTee.attach(to: source, fileURL: fileURL)

        for _ in 0..<3 {
            continuation.yield(try constantBuffer(sampleValue: 0.25, frameCount: 256))
        }
        continuation.finish()

        var forwardedCount = 0
        for try await _ in tee.stream {
            forwardedCount += 1
        }

        #expect(await tee.waitForCompletion() == false)
        #expect(forwardedCount == 3)
        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) == false)
    }

    @Test
    func slowArchiveWriterNeverDelaysForwardingAndAbandonsTheFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let fileURL = try await archive.beginEntry(id: UUID())
        let writerGate = DispatchSemaphore(value: 0)
        let (source, continuation) = AudioBufferSequence.makeStream()
        let tee = RecordingTee.attach(
            to: source,
            fileURL: fileURL,
            writeCapacity: 1,
            makeAudioFile: { _, _ in BlockingRecordingFile(gate: writerGate) }
        )

        for _ in 0..<5 {
            continuation.yield(try constantBuffer(sampleValue: 0.25, frameCount: 256))
        }
        continuation.finish()

        var forwardedCount = 0
        for try await _ in tee.stream {
            forwardedCount += 1
        }
        #expect(forwardedCount == 5)

        writerGate.signal()
        #expect(await tee.waitForCompletion() == false)
        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) == false)
    }

    @Test
    func teeWriteFailureRemovesThePlaceholderAndCommitReconcilesTheSidecar() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let id = UUID()
        let fileURL = try await archive.beginEntry(id: id)
        let (source, continuation) = AudioBufferSequence.makeStream()
        let tee = RecordingTee.attach(
            to: source,
            fileURL: fileURL,
            makeAudioFile: { _, _ in FailingRecordingFile() }
        )

        for _ in 0..<3 {
            continuation.yield(try constantBuffer(sampleValue: 0.25, frameCount: 256))
        }
        continuation.finish()

        var forwardedCount = 0
        for try await _ in tee.stream {
            forwardedCount += 1
        }
        #expect(await tee.waitForCompletion() == false)
        await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "deploy")

        #expect(forwardedCount == 3)
        #expect(entryExists(id: id, in: directory) == false)
        #expect(await archive.pendingEntries().isEmpty)
    }

    @Test
    func cancelledTeeStopsBeforeTheArchiveIsDiscarded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let id = UUID()
        let fileURL = try await archive.beginEntry(id: id)
        let (source, continuation) = AudioBufferSequence.makeStream()
        let tee = RecordingTee.attach(to: source, fileURL: fileURL)

        continuation.yield(try constantBuffer(sampleValue: 0.25, frameCount: 256))
        await tee.cancelAndWait()
        await archive.discardEntry(id: id)
        continuation.finish()

        #expect(FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) == false)
        #expect(await archive.pendingEntries().isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: testDomainName("SyrupRecordingArchiveTests"), directoryHint: .isDirectory)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path(percentEncoded: false)
        )
        let value = try #require(attributes[.posixPermissions] as? NSNumber)
        return value.intValue & 0o777
    }

    private func entryExists(id: UUID, in directory: URL) -> Bool {
        let audioURL = directory.appending(path: "\(id.uuidString).wav")
        let sidecarURL = directory.appending(path: "\(id.uuidString).json")
        return FileManager.default.fileExists(atPath: audioURL.path(percentEncoded: false))
            && FileManager.default.fileExists(atPath: sidecarURL.path(percentEncoded: false))
    }

    private func constantBuffer(
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
}

private final class FailingRecordingFile: RecordingFileWriting {
    private var writeCount = 0

    func write(from buffer: AVAudioPCMBuffer) throws {
        writeCount += 1
        if writeCount == 2 {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class BlockingRecordingFile: RecordingFileWriting, @unchecked Sendable {
    private let gate: DispatchSemaphore
    private var opened = false

    init(gate: DispatchSemaphore) {
        self.gate = gate
    }

    func write(from buffer: AVAudioPCMBuffer) throws {
        guard opened == false else { return }
        opened = true
        gate.wait()
    }
}

private final class FailingFilePermissionManager: FileManager {
    override func setAttributes(
        _ attributes: [FileAttributeKey: Any],
        ofItemAtPath path: String
    ) throws {
        if path.hasSuffix(".wav") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

private final class DeletionGate: Sendable {
    private let denies = Mutex(false)

    var deniesDeletion: Bool {
        get { denies.withLock { $0 } }
        set { denies.withLock { $0 = newValue } }
    }
}

private final class DeletionDenyingFileManager: FileManager {
    private let gate: DeletionGate

    init(gate: DeletionGate) {
        self.gate = gate
        super.init()
    }

    override func removeItem(at url: URL) throws {
        if gate.deniesDeletion { throw CocoaError(.fileWriteNoPermission) }
        try super.removeItem(at: url)
    }
}

private final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ date: Date) {
        self.date = Mutex(date)
    }

    var now: Date {
        date.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        date.withLock { $0.addTimeInterval(interval) }
    }
}
