import AVFoundation
import Foundation
import KeyboardShortcuts
import Synchronization
import Testing
@testable import Syrup

/// Pending-recording counts published to Settings.
@MainActor
struct RecordingArchiveCountTests {
    @Test func archiveCountsFollowCommitsDeletesAndNewSubscribers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupCountCorrection"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = RecordingArchive(storageDirectory: directory)
        let counts = await archive.pendingEntryCounts()
        #expect(try await nextCount(counts) == 0)
        let id = UUID()
        _ = try await archive.beginEntry(id: id)
        await archive.commitEntry(id: id, localeID: "pt-BR", appleTranscript: "fixture")
        #expect(try await nextCount(counts) == 1)
        await archive.deleteEntry(id: id)
        #expect(try await nextCount(counts) == 0)
        let next = await archive.pendingEntryCounts()
        #expect(try await nextCount(next) == 0)
        let otherID = UUID()
        _ = try await archive.beginEntry(id: otherID)
        await archive.commitEntry(id: otherID, localeID: "pt-BR", appleTranscript: "fixture")
        #expect(try await nextCount(next) == 1)
        try await archive.deleteAll()
        #expect(try await nextCount(next) == 0)
    }

    private func nextCount(_ counts: AsyncStream<Int>) async throws -> Int? {
        try await withOperationTimeout(.seconds(2), error: TranslationError.timedOut) {
            await counts.first { _ in true }
        }
    }
}
