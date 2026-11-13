import Foundation
import Observation

/// Keeps usage numbers in memory and writes them off the main actor, so delivery never waits on the disk.
@MainActor
@Observable
final class UsageStatsStore {
    private(set) var stats: UsageStats
    @ObservationIgnored private let disk: UsageStatsDisk?

    /// A nil file keeps stats in memory only.
    init(fileURL: URL? = nil) {
        disk = fileURL.map(UsageStatsDisk.init(fileURL:))
        stats = fileURL.flatMap { try? Data(contentsOf: $0) }
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
        Task { await disk.write(stats) }
    }

    func deleteAll() {
        stats = UsageStats()
        guard let disk else { return }
        Task { await disk.delete() }
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

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
