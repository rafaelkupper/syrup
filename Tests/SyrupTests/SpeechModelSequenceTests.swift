import Foundation
import Synchronization
import Testing
@testable import Syrup

/// Every sequence of up to three model operations, made back to back as quick clicks would make
/// them, from a model on disk and from none. Once the work settles, the manager must agree with the
/// disk, and no two downloads may ever have run at once. Bugs in this manager came from one operation
/// arriving while another was still under way; the single-case tests covered only the pairs someone
/// thought of.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SpeechModelSequenceTests {
    enum Step: String, CaseIterable, Sendable {
        case download, cancel, delete, load, retry
    }

    static let sequences: [[Step]] = {
        var all: [[Step]] = []
        var frontier: [[Step]] = [[]]
        for _ in 1...3 {
            frontier = frontier.flatMap { sequence in Step.allCases.map { sequence + [$0] } }
            all += frontier
        }
        return all
    }()

    @Test(arguments: [false, true])
    func everySequenceLeavesTheManagerAgreeingWithTheDisk(startsOnDisk: Bool) async throws {
        #expect(Self.sequences.count == 155)
        for sequence in Self.sequences {
            let fixture = try SequenceFixture(startsOnDisk: startsOnDisk)
            defer { fixture.clean() }
            for step in sequence {
                switch step {
                case .download: fixture.manager.download()
                case .cancel: fixture.manager.cancelDownload()
                case .delete: fixture.manager.remove()
                case .load: fixture.manager.loadIfDownloaded()
                case .retry: fixture.manager.retry()
                }
            }
            await fixture.manager.waitUntilIdle()

            let label = "\(startsOnDisk ? "on disk" : "absent"), then \(sequence.map(\.rawValue).joined(separator: ", "))"
            let state = fixture.manager.state
            #expect(fixture.mostDownloadsAtOnce <= 1, "Two downloads at once: \(label)")
            switch state {
            case .downloaded, .ready:
                #expect(fixture.modelIsOnDisk, "\(state) without a model on disk: \(label)")
            case .notDownloaded:
                #expect(fixture.modelIsOnDisk == false, "Not downloaded, yet a model is on disk: \(label)")
            case .downloading, .loading:
                Issue.record("Still \(state) after the work settled: \(label)")
            case .failed, .unsupported:
                break
            }
        }
    }
}

/// A model folder with a marker file, written by a download that takes a moment and stops when
/// cancelled, and a load that fails without the marker.
@MainActor
private final class SequenceFixture {
    let root: URL
    let manager: SpeechModelManager
    private let downloads = DownloadCounter()

    var mostDownloadsAtOnce: Int { downloads.most }
    var modelIsOnDisk: Bool { Self.isComplete(manager.directory) }

    init(startsOnDisk: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelSequence"), directoryHint: .isDirectory)
        self.root = root
        if startsOnDisk {
            let engine = SpeechEngine.parakeetUltra
            try Self.writeModel(at: root.appending(path: engine.modelFolder ?? engine.rawValue, directoryHint: .isDirectory))
        }
        let downloads = self.downloads
        manager = SpeechModelManager(
            engine: .parakeetUltra,
            operations: .init(
                modelsExist: { Self.isComplete($0) },
                download: { directory, _ in
                    downloads.begin()
                    defer { downloads.end() }
                    try await Task.sleep(for: .milliseconds(2))
                    try Self.writeModel(at: directory)
                },
                load: { directory in
                    guard Self.isComplete(directory) else { throw CocoaError(.fileReadNoSuchFile) }
                },
                unload: {}
            ),
            isSupported: true,
            storageDirectory: root
        )
        #expect(manager.state == (startsOnDisk ? .downloaded : .notDownloaded))
    }

    func clean() {
        try? FileManager.default.removeItem(at: root)
    }

    nonisolated private static func isComplete(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: "weights.bin").path(percentEncoded: false))
    }

    nonisolated private static func writeModel(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: directory.appending(path: "weights.bin"))
    }
}

private final class DownloadCounter: Sendable {
    private let counts = Mutex((running: 0, most: 0))
    var most: Int { counts.withLock { $0.most } }

    func begin() {
        counts.withLock {
            $0.running += 1
            $0.most = max($0.most, $0.running)
        }
    }

    func end() {
        counts.withLock { $0.running -= 1 }
    }
}
