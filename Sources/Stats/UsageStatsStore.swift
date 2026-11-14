import Foundation
import Observation

/// Keeps usage numbers in memory and writes them off the main actor, so delivery never waits on the disk.
@MainActor
@Observable
final class UsageStatsStore {
    private(set) var stats: UsageStats
    /// Set when Delete Stats could not remove the file. Stats then show what is still on disk.
    private(set) var deletionError: String?
    @ObservationIgnored private let disk: UsageStatsDisk?
    @ObservationIgnored private let fileURL: URL?
    /// The last disk operation. Each new one waits for it, so a slow write can never land after a
    /// later delete and bring cleared stats back.
    @ObservationIgnored private var lastDiskWork: Task<Void, Never>?

    /// A nil file keeps stats in memory only.
    init(fileURL: URL? = nil) {
        disk = fileURL.map(UsageStatsDisk.init(fileURL:))
        self.fileURL = fileURL
        stats = Self.load(fileURL)
    }

    private static func load(_ fileURL: URL?) -> UsageStats {
        fileURL.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONDecoder().decode(UsageStats.self, from: $0) } ?? UsageStats()
    }

    func record(
        words: Int,
        seconds: Double,
        fixes: Int,
        appBundleID: String?,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        stats.record(words: words, seconds: seconds, fixes: fixes, appBundleID: appBundleID, now: now, calendar: calendar)
        guard let disk else { return }
        let stats = stats
        enqueue { await disk.write(stats) }
    }

    /// Clears the stats at once, then deletes the file after any queued write. If the file survives,
    /// the stats on disk come back on screen with an error, instead of returning silently at the next
    /// launch. Returns whether the file is gone.
    @discardableResult
    func deleteAll() async -> Bool {
        stats = UsageStats()
        deletionError = nil
        guard let disk else { return true }
        let previous = lastDiskWork
        let deletion = Task { () -> Bool in
            await previous?.value
            return await disk.delete()
        }
        lastDiskWork = Task { _ = await deletion.value }
        let deleted = await deletion.value
        if deleted == false {
            stats = Self.load(fileURL)
            deletionError = "Usage stats could not be deleted from this Mac. Check the permissions of Application Support/Syrup."
        }
        return deleted
    }

    /// Waits until every queued write and delete has reached the disk.
    func flush() async {
        await lastDiskWork?.value
    }

    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        let previous = lastDiskWork
        lastDiskWork = Task {
            await previous?.value
            await operation()
        }
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appending(path: "Syrup", directoryHint: .isDirectory)
            .appending(path: "usage-stats.json")
    }
}

actor UsageStatsDisk {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func write(_ stats: UsageStats) {
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(stats)
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path(percentEncoded: false))
        } catch {
            // Stats are best effort. The next dictation writes the whole file again.
        }
    }

    /// True when the file is gone afterward, including when there was none.
    func delete() -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) == false
        }
    }
}
