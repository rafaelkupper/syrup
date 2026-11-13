import Foundation
import Observation
import OSLog

@MainActor
protocol HistoryRecording: AnyObject {
    var records: [DictationRecord] { get }
    func append(_ record: DictationRecord)
    func clear() async -> Bool
}

@MainActor
@Observable
final class HistoryStore: HistoryRecording {
    static let defaultCapacity = 20

    var records: [DictationRecord] = []
    private(set) var persistenceError: String?
    private(set) var isChangingPersistence = false

    @ObservationIgnored private let capacity: Int
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "History")
    @ObservationIgnored private var isPersistenceEnabled: Bool
    @ObservationIgnored private let disk: HistoryDisk
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    init(
        capacity: Int = HistoryStore.defaultCapacity,
        persistenceEnabled: Bool = false,
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.capacity = max(1, capacity)
        self.fileManager = fileManager
        self.isPersistenceEnabled = persistenceEnabled
        let baseDirectory = storageDirectory ?? Self.defaultStorageDirectory(fileManager: fileManager)
        self.fileURL = baseDirectory.appending(path: "history.json")
        self.disk = HistoryDisk(fileURL: self.fileURL)

        if persistenceEnabled {
            loadFromDisk()
        }
    }

    func append(_ record: DictationRecord) {
        records.insert(record, at: 0)
        if records.count > capacity {
            records.removeLast(records.count - capacity)
        }
        saveIfNeeded()
    }

    @discardableResult
    func clear() async -> Bool {
        guard isChangingPersistence == false else { return false }
        let removedIDs = Set(records.map(\.id))
        isChangingPersistence = true
        await flush()
        do {
            try await disk.delete()
            records.removeAll { removedIDs.contains($0.id) }
            persistenceError = nil
            isChangingPersistence = false
            if records.isEmpty == false { saveIfNeeded() }
            return true
        } catch {
            persistenceError = "History could not be deleted. Existing history was kept."
            isChangingPersistence = false
            saveIfNeeded()
            return false
        }
    }

    @discardableResult
    func setPersistenceEnabled(_ isEnabled: Bool) async -> Bool {
        guard isChangingPersistence == false else { return false }
        guard isEnabled != isPersistenceEnabled else { return true }
        if isEnabled {
            isPersistenceEnabled = true
            saveIfNeeded()
            return true
        }
        isChangingPersistence = true
        await flush()
        do {
            try await disk.delete()
            isPersistenceEnabled = false
            persistenceError = nil
            isChangingPersistence = false
            return true
        } catch {
            persistenceError = "History could not be deleted. Keep history remains enabled."
            isChangingPersistence = false
            saveIfNeeded()
            return false
        }
    }

    func flush() async { await pendingWrite?.value }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: fileURL.path(percentEncoded: false)) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            let decodedRecords = try JSONDecoder().decode([DictationRecord].self, from: data)
            records = Array(decodedRecords.prefix(capacity))
        } catch {
            logger.error("history_load_failed code=\((error as NSError).code, privacy: .public)")
            records = []
        }
    }

    private func saveIfNeeded() {
        guard isPersistenceEnabled, isChangingPersistence == false else { return }
        let snapshot = records
        let previous = pendingWrite
        pendingWrite = Task { [weak self, disk] in
            await previous?.value
            do {
                try await disk.save(snapshot)
            } catch {
                self?.persistenceError = "History could not be saved. Recent results remain available in memory."
            }
        }
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return baseURL
            .appending(path: "Syrup", directoryHint: .isDirectory)
            .appending(path: "History", directoryHint: .isDirectory)
    }
}

private actor HistoryDisk {
    let fileURL: URL
    let fileManager = FileManager()

    init(fileURL: URL) { self.fileURL = fileURL }

    func save(_ records: [DictationRecord]) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func delete() throws {
        do {
            try fileManager.removeItem(at: fileURL)
        } catch CocoaError.fileNoSuchFile {
            // Already absent is the only deletion error that means success.
        }
    }
}
