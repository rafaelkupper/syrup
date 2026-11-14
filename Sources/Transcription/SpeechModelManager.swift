import Foundation
import Observation

@MainActor
@Observable
final class SpeechModelManager: SpeechModelProviding {
    struct Operations: Sendable {
        var modelsExist: @Sendable (URL) -> Bool
        var download: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void
        var load: @Sendable (URL) async throws -> Void
        var unload: @Sendable () async -> Void
    }

    let engine: SpeechEngine
    private(set) var state: SpeechModelState
    let directory: URL
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private var generation = 0

    init(
        engine: SpeechEngine,
        operations: Operations,
        isSupported: Bool,
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let storageDirectory = storageDirectory ?? Self.defaultStorageDirectory(fileManager: fileManager)
        self.engine = engine
        self.operations = operations
        self.fileManager = fileManager
        directory = storageDirectory.appending(path: engine.modelFolder ?? engine.rawValue, directoryHint: .isDirectory)
        if isSupported == false {
            state = .unsupported
        } else {
            state = operations.modelsExist(directory) ? .downloaded : .notDownloaded
        }
    }

    /// Unfinished downloads wait here, beside the model, so they can resume and are removed with it.
    nonisolated static func stagingDirectory(for directory: URL) -> URL {
        directory.deletingLastPathComponent().appending(
            path: ".partial-\(directory.lastPathComponent)", directoryHint: .isDirectory
        )
    }

    /// `onDownloaded` runs once the model is on disk, before it loads.
    func download(onDownloaded: (@MainActor () -> Void)? = nil) {
        switch state {
        case .notDownloaded, .failed:
            break
        case .unsupported, .downloading, .downloaded, .loading, .ready:
            return
        }

        generation += 1
        let generation = generation
        state = .downloading(0)
        let directory = directory
        Task {
            do {
                try protectStorageDirectory()
                try await operations.download(directory) { fraction in
                    Task { @MainActor in self.updateDownloadProgress(fraction, generation: generation) }
                }
                onDownloaded?()
                guard generation == self.generation else { return }
                await load(generation: generation)
            } catch is CancellationError {
                if generation == self.generation { state = .notDownloaded }
            } catch {
                if generation == self.generation { state = .failed("Download failed.") }
            }
        }
    }

    /// Retry after a failure. A model that downloaded but failed to load is loaded again; downloading
    /// it again would fetch it into staging and then fail to move it onto the copy already there.
    func retry() {
        guard case .failed = state else { return }
        guard operations.modelsExist(directory) else {
            download()
            return
        }
        generation += 1
        let generation = generation
        state = .loading
        Task { await load(generation: generation) }
    }

    func loadIfDownloaded() {
        guard state == .downloaded else { return }
        generation += 1
        let generation = generation
        state = .loading
        Task { await load(generation: generation) }
    }

    func remove() {
        switch state {
        case .downloading, .loading:
            return
        case .unsupported, .notDownloaded, .downloaded, .ready, .failed:
            break
        }

        generation += 1
        let generation = generation
        Task {
            await operations.unload()
            guard generation == self.generation else { return }
            for folder in [directory, Self.stagingDirectory(for: directory)]
            where fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
                do {
                    try fileManager.removeItem(at: folder)
                } catch {
                    state = .failed("Couldn't remove the model.")
                    return
                }
            }
            state = .notDownloaded
        }
    }

    private func load(generation: Int) async {
        state = .loading
        do {
            try await operations.load(directory)
            if generation == self.generation { state = .ready }
        } catch {
            if generation == self.generation { state = .failed("The model couldn't load.") }
        }
    }

    private func protectStorageDirectory() throws {
        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path(percentEncoded: false))
    }

    private func updateDownloadProgress(_ fraction: Double, generation: Int) {
        guard generation == self.generation, case .downloading(let current) = state else { return }
        state = .downloading(max(current, min(max(fraction, 0), 1)))
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appending(path: "Syrup", directoryHint: .isDirectory)
            .appending(path: "SpeechModels", directoryHint: .isDirectory)
    }
}
