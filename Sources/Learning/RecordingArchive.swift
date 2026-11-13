import Foundation
import OSLog

struct RecordingSidecar: Codable, Equatable, Sendable {
    let id: UUID
    let createdAt: Date
    let localeID: String
    let appleTranscript: String
    var attempts: Int
    var nextAttemptAt: Date? = nil
}

enum RecordingArchiveError: Error, Equatable, Sendable {
    case beginFailed(code: Int)
    case deleteAllFailed(code: Int)
}

protocol RecordingArchiving: AnyObject, Sendable {
    /// Begins an entry; returns the audio file URL to write into.
    func beginEntry(id: UUID) async throws -> URL
    /// Finalizes an entry once the run committed a non-empty transcript.
    func commitEntry(id: UUID, localeID: String, appleTranscript: String) async
    /// Removes a never-committed entry (cancel/error/empty transcript).
    func discardEntry(id: UUID) async
    func pendingEntries() async -> [RecordingSidecar]
    func pendingEntryCounts() async -> AsyncStream<Int>
    func audioFileURL(id: UUID) async -> URL
    func recordAttempt(id: UUID) async -> Int
    func deleteEntry(id: UUID) async
    func deleteAll() async throws
}

actor RecordingArchive: RecordingArchiving {
    static let defaultMaxEntries = 50
    static let defaultMaxAge: TimeInterval = 7 * 24 * 60 * 60

    private var activeIDs: Set<UUID> = []
    private var countObservers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var lastPublishedCount: Int?
    private let storageDirectory: URL
    private let fileManager: FileManager
    private let maxEntries: Int
    private let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private let logger = Logger(
        subsystem: "org.syrup.SyrupApp",
        category: "RecordingArchive"
    )

    init(
        maxEntries: Int = RecordingArchive.defaultMaxEntries,
        maxAge: TimeInterval = RecordingArchive.defaultMaxAge,
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.maxEntries = max(0, maxEntries)
        self.maxAge = max(0, maxAge)
        self.fileManager = fileManager
        self.storageDirectory = storageDirectory
            ?? Self.defaultStorageDirectory(fileManager: fileManager)
        self.now = now
    }

    func beginEntry(id: UUID) throws -> URL {
        let audioURL = fileURL(id: id, extension: "wav")

        do {
            try ensureDirectory()
            try Data().write(to: audioURL, options: .atomic)
            try setOwnerOnlyFilePermissions(at: audioURL)
            activeIDs.insert(id)
            return audioURL
        } catch {
            removeIfPresent(audioURL)
            logFailure("begin", error: error)
            throw RecordingArchiveError.beginFailed(code: (error as NSError).code)
        }
    }

    func commitEntry(id: UUID, localeID: String, appleTranscript: String) {
        guard activeIDs.remove(id) != nil else { return }
        defer { publishPendingCount() }
        let sidecar = RecordingSidecar(
            id: id,
            createdAt: now(),
            localeID: localeID,
            appleTranscript: appleTranscript,
            attempts: 0
        )
        let sidecarURL = fileURL(id: id, extension: "json")

        do {
            try ensureDirectory()
            let data = try JSONEncoder().encode(sidecar)
            try data.write(to: sidecarURL, options: .atomic)
            try setOwnerOnlyFilePermissions(at: sidecarURL)
            enforceCaps()
        } catch {
            logFailure("commit", error: error)
            discardEntry(id: id)
        }
    }

    func discardEntry(id: UUID) {
        deleteEntry(id: id)
        removeDirectoryIfEmpty()
    }

    func pendingEntries() -> [RecordingSidecar] {
        defer { publishPendingCount() }
        guard fileManager.fileExists(atPath: storageDirectory.path(percentEncoded: false)) else {
            return []
        }

        enforceCaps()
        return decodedPendingEntries()
    }

    func pendingEntryCounts() -> AsyncStream<Int> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let count = pendingEntries().count
        continuation.yield(count)
        if countObservers.isEmpty { lastPublishedCount = count }
        countObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeCountObserver(id) }
        }
        return stream
    }

    private func removeCountObserver(_ id: UUID) {
        countObservers[id] = nil
    }

    private func publishPendingCount() {
        guard countObservers.isEmpty == false else { return }
        let count = fileManager.fileExists(atPath: storageDirectory.path) ? decodedPendingEntries().count : 0
        guard count != lastPublishedCount else { return }
        lastPublishedCount = count
        for observer in countObservers.values { observer.yield(count) }
    }

    func audioFileURL(id: UUID) -> URL {
        fileURL(id: id, extension: "wav")
    }

    func recordAttempt(id: UUID) -> Int {
        let sidecarURL = fileURL(id: id, extension: "json")
        do {
            let data = try Data(contentsOf: sidecarURL)
            var sidecar = try JSONDecoder().decode(RecordingSidecar.self, from: data)
            sidecar.attempts += 1
            sidecar.nextAttemptAt = now().addingTimeInterval(min(86_400, 1_800 * pow(2, Double(min(sidecar.attempts - 1, 6)))))
            let updatedData = try JSONEncoder().encode(sidecar)
            try updatedData.write(to: sidecarURL, options: .atomic)
            try setOwnerOnlyFilePermissions(at: sidecarURL)
            return sidecar.attempts
        } catch {
            logFailure("record_attempt", error: error)
            discardEntry(id: id)
            return 3
        }
    }

    private func decodedPendingEntries() -> [RecordingSidecar] {
        do {
            return try recordingArtifactURLs()
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                do {
                    let data = try Data(contentsOf: url)
                    return try JSONDecoder().decode(RecordingSidecar.self, from: data)
                } catch {
                    logFailure("decode", error: error)
                    return nil
                }
            }
            .sorted(by: Self.oldestFirst)
        } catch {
            logFailure("list", error: error)
            return []
        }
    }

    func deleteEntry(id: UUID) {
        removeEntry(id: id)
        publishPendingCount()
    }

    private func removeEntry(id: UUID) {
        activeIDs.remove(id)
        removeIfPresent(fileURL(id: id, extension: "wav"))
        removeIfPresent(fileURL(id: id, extension: "json"))
    }

    func deleteAll() throws {
        defer { publishPendingCount() }
        activeIDs.removeAll()
        guard fileManager.fileExists(atPath: storageDirectory.path(percentEncoded: false)) else {
            return
        }

        do {
            try fileManager.removeItem(at: storageDirectory)
        } catch {
            logFailure("delete_all", error: error)
            throw RecordingArchiveError.deleteAllFailed(code: (error as NSError).code)
        }
    }

    private func enforceCaps() {
        guard fileManager.fileExists(atPath: storageDirectory.path(percentEncoded: false)) else {
            return
        }
        reconcileInvalidArtifacts()
        let cutoff = now().addingTimeInterval(-maxAge)
        let entries = decodedPendingEntries()
        let expiredEntries = entries.filter { $0.createdAt < cutoff }
        expiredEntries.forEach { removeEntry(id: $0.id) }

        let retainedEntries = entries.filter { $0.createdAt >= cutoff }
        let excessCount = max(0, retainedEntries.count - maxEntries)
        retainedEntries.prefix(excessCount).forEach { removeEntry(id: $0.id) }
    }

    private func reconcileInvalidArtifacts() {
        do {
            let groupedArtifacts = Dictionary(
                grouping: try recordingArtifactURLs(),
                by: { $0.deletingPathExtension().lastPathComponent.lowercased() }
            )

            for (stem, urls) in groupedArtifacts {
                if let id = UUID(uuidString: stem), activeIDs.contains(id) { continue }
                let audioURL = urls.first { $0.pathExtension.lowercased() == "wav" }
                let sidecarURL = urls.first { $0.pathExtension.lowercased() == "json" }
                let sidecar = sidecarURL.flatMap { url -> RecordingSidecar? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(RecordingSidecar.self, from: data)
                }
                let hasMatchingPair = audioURL != nil
                    && sidecarURL != nil
                    && sidecar?.id.uuidString.lowercased() == stem

                if hasMatchingPair == false {
                    urls.forEach(removeIfPresent)
                }
            }
        } catch {
            logFailure("reconcile", error: error)
        }
    }

    private func ensureDirectory() throws {
        try fileManager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: storageDirectory.path(percentEncoded: false)
        )
    }

    private func setOwnerOnlyFilePermissions(at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    private func removeIfPresent(_ url: URL) {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else {
            return
        }

        do {
            try fileManager.removeItem(at: url)
        } catch {
            logFailure("delete", error: error)
        }
    }

    private func removeDirectoryIfEmpty() {
        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: storageDirectory,
                includingPropertiesForKeys: nil
            ),
            contents.isEmpty
        else {
            return
        }

        removeIfPresent(storageDirectory)
    }

    private func recordingArtifactURLs() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: storageDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let pathExtension = url.pathExtension.lowercased()
            return pathExtension == "wav" || pathExtension == "json"
        }
    }

    private func fileURL(id: UUID, extension pathExtension: String) -> URL {
        storageDirectory.appending(path: "\(id.uuidString).\(pathExtension)")
    }

    private func logFailure(_ operation: String, error: Error) {
        logger.error(
            "recording_archive_failed operation=\(operation, privacy: .public) code=\((error as NSError).code, privacy: .public)"
        )
    }

    private static func oldestFirst(_ lhs: RecordingSidecar, _ rhs: RecordingSidecar) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.createdAt < rhs.createdAt
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return baseURL
            .appending(path: "Syrup", directoryHint: .isDirectory)
            .appending(path: "Recordings", directoryHint: .isDirectory)
    }
}
