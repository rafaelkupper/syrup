import Foundation
import Synchronization
import Testing
@testable import Syrup

/// The comparison model's download, cancel, removal, and retry, with fakes that write exactly the
/// files Hugging Face publishes (`WhisperPublishedLayout`), never a layout the code assumes.
@MainActor
struct WhisperModelRemovalTests {
    private func storage() -> URL {
        FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupWhisperModelTests"), directoryHint: .isDirectory)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @Test
    func removeModelDeletesFilesAndResetsState() async throws {
        let storageDirectory = storage()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        try WhisperPublishedLayout.write(in: storageDirectory, tokenizer: true)
        let manager = WhisperModelManager(storageDirectory: storageDirectory)
        #expect(manager.state == .ready)

        manager.removeModel()
        #expect(manager.state == .notDownloaded)
        await manager.waitUntilIdle()

        #expect(manager.state == .notDownloaded)
        #expect(exists(storageDirectory) == false)
    }

    @Test
    func removeModelWithoutFilesIsANoOpReset() async {
        let manager = WhisperModelManager(storageDirectory: storage())
        #expect(manager.state == .notDownloaded)
        manager.removeModel()
        await manager.waitUntilIdle()
        #expect(manager.state == .notDownloaded)
    }

    /// The download WhisperKit makes, as published: three bundles and two configs, then the tokenizer
    /// from its own repository. It becomes ready, with nothing left in staging.
    @Test
    func aDownloadOfThePublishedFilesBecomesReady() async throws {
        let storageDirectory = storage()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let fetched = FetchLog()
        let manager = WhisperModelManager(storageDirectory: storageDirectory, operations: .published(fetched))

        await manager.ensureModel()

        #expect(manager.state == .ready)
        #expect(fetched.values == ["model", "tokenizer"])
        #expect(exists(manager.modelDirectory.appending(path: "TextDecoder.mlmodelc/weights/weight.bin")))
        #expect(exists(manager.tokenizerDirectory.appending(path: "tokenizer.json")))
        #expect(exists(storageDirectory.appending(path: ".partial")) == false)
        #expect(WhisperModelManager(storageDirectory: storageDirectory).state == .ready, "Ready again at the next launch")
    }

    /// An earlier build downloaded the model in place, without the tokenizer. It fetches only the
    /// tokenizer, not 626 MB again.
    @Test
    func aModelAlreadyOnDiskFetchesOnlyItsTokenizer() async throws {
        let storageDirectory = storage()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        try WhisperPublishedLayout.write(in: storageDirectory, tokenizer: false)
        let fetched = FetchLog()
        let manager = WhisperModelManager(storageDirectory: storageDirectory, operations: .published(fetched))
        #expect(manager.state == .notDownloaded)

        await manager.ensureModel()

        #expect(fetched.values == ["tokenizer"])
        #expect(manager.state == .ready)
    }

    @Test
    func aDownloadMissingAModelFileFails() async throws {
        let storageDirectory = storage()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let manager = WhisperModelManager(storageDirectory: storageDirectory, operations: .init(
            downloadModel: { base, _ in
                try WhisperPublishedLayout.writeModel(in: base)
                try FileManager.default.removeItem(at: WhisperPublishedLayout.modelFolder(in: base).appending(path: "AudioEncoder.mlmodelc/weights/weight.bin"))
            },
            downloadTokenizer: { try WhisperPublishedLayout.writeTokenizer(in: $0) }
        ))

        await manager.ensureModel()

        #expect(manager.state == .failed("Recognition model download failed."))
        #expect(exists(manager.modelDirectory) == false)
    }

    /// Cancel stops the download, and nothing it fetched is moved into place.
    @Test
    func cancelStopsTheDownloadAndMovesNothingIntoPlace() async throws {
        let storageDirectory = storage()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let manager = WhisperModelManager(storageDirectory: storageDirectory, operations: .waitingForCancel())
        let download = Task { await manager.ensureModel() }
        await eventually { manager.state == .downloading(0) }

        manager.cancelDownload()
        #expect(manager.state == .notDownloaded)
        await download.value
        await manager.waitUntilIdle()

        #expect(manager.state == .notDownloaded)
        #expect(exists(manager.modelDirectory) == false)
    }

    /// Delete during a download, as turning learning off and removing the model does: the download
    /// stops, then the files go.
    @Test
    func deleteDuringADownloadCancelsItThenRemovesTheFiles() async throws {
        let storageDirectory = storage()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        let manager = WhisperModelManager(storageDirectory: storageDirectory, operations: .waitingForCancel())
        let download = Task { await manager.ensureModel() }
        await eventually { manager.state == .downloading(0) }

        manager.removeModel()
        await download.value
        await manager.waitUntilIdle()

        #expect(manager.state == .notDownloaded)
        #expect(exists(storageDirectory) == false)
    }

    /// After a load failed, passes leave the model alone; Retry downloads it again in full, since the
    /// copy on disk is not trusted.
    @Test
    func aModelThatFailedToLoadIsDownloadedAgainOnlyOnRetry() async throws {
        let storageDirectory = storage()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }
        try WhisperPublishedLayout.write(in: storageDirectory, tokenizer: true)
        let fetched = FetchLog()
        let manager = WhisperModelManager(storageDirectory: storageDirectory, operations: .published(fetched))
        manager.modelFailedToLoad()

        await manager.ensureModel()
        #expect(fetched.values.isEmpty)

        await manager.retry()
        #expect(fetched.values == ["model", "tokenizer"])
        #expect(manager.state == .ready)
    }

    /// Retry after a failed removal tries the removal again, not a download.
    @Test
    func retryAfterAFailedRemovalRemovesAgain() async throws {
        let parent = storage()
        let storageDirectory = parent.appending(path: "WhisperModels", directoryHint: .isDirectory)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path(percentEncoded: false))
            try? FileManager.default.removeItem(at: parent)
        }
        try WhisperPublishedLayout.write(in: storageDirectory, tokenizer: true)
        let fetched = FetchLog()
        let manager = WhisperModelManager(storageDirectory: storageDirectory, operations: .published(fetched))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path(percentEncoded: false))

        manager.removeModel()
        await manager.waitUntilIdle()
        #expect(manager.state == .failed("Couldn't remove the recognition model."))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path(percentEncoded: false))
        await manager.retry()
        #expect(manager.state == .notDownloaded)
        #expect(exists(storageDirectory) == false)
        #expect(fetched.values.isEmpty)
    }
}

private final class FetchLog: Sendable {
    private let entries = Mutex<[String]>([])
    var values: [String] { entries.withLock { $0 } }
    func record(_ entry: String) { entries.withLock { $0.append(entry) } }
}

private extension WhisperModelManager.Operations {
    /// Writes the published files and records what was fetched.
    static func published(_ log: FetchLog) -> Self {
        .init(
            downloadModel: { base, _ in
                log.record("model")
                try WhisperPublishedLayout.writeModel(in: base)
            },
            downloadTokenizer: { base in
                log.record("tokenizer")
                try WhisperPublishedLayout.writeTokenizer(in: base)
            }
        )
    }

    /// A model download that runs until cancelled.
    static func waitingForCancel() -> Self {
        .init(
            downloadModel: { _, _ in try await Task.sleep(for: .seconds(3_600)) },
            downloadTokenizer: { try WhisperPublishedLayout.writeTokenizer(in: $0) }
        )
    }
}
