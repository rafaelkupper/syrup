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
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    /// The latest download, load, or removal. The next one waits for it: a cancelled download can
    /// take a while to stop, downloads and removals use the same folders, and a removal must not
    /// interleave with a load.
    @ObservationIgnored private var lastOperation: Task<Void, Never>?
    /// A folder this model is taking over from; see `replace`.
    @ObservationIgnored private var replacedDirectory: URL?

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

    func download() {
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
        let previous = lastOperation
        let task = Task {
            await previous?.value
            guard generation == self.generation else { return }
            do {
                try protectStorageDirectory()
                try await operations.download(directory) { fraction in
                    Task { @MainActor in self.updateDownloadProgress(fraction, generation: generation) }
                }
                guard generation == self.generation else { return }
                removeReplacedDirectory()
                await load(generation: generation)
            } catch {
                if generation == self.generation { state = .failed("Download failed.") }
            }
        }
        downloadTask = task
        lastOperation = task
    }

    /// Stops a download in progress. Files that finished stay in the staging folder, so the next
    /// download can keep them; it starts once this one has stopped. A handover this download was
    /// making (see `replace`) ends too.
    func cancelDownload() {
        guard case .downloading = state else { return }
        generation += 1
        downloadTask?.cancel()
        state = .notDownloaded
        removeReplacedDirectory()
    }

    /// Takes over from an older model's folder: downloads this model if it is missing and deletes the
    /// older folder once this one is on disk. If the download fails, the older folder stays and the
    /// next launch tries again. If the person cancels or deletes this model instead, the older
    /// folder goes too, so a handover they stopped does not start again at every launch.
    func replace(_ olderDirectory: URL) {
        replacedDirectory = olderDirectory
        switch state {
        case .downloaded, .loading, .ready:
            removeReplacedDirectory()
        case .notDownloaded, .failed:
            download()
        case .downloading, .unsupported:
            break
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
        startLoad()
    }

    func loadIfDownloaded() {
        guard state == .downloaded else { return }
        startLoad()
    }

    /// Loads in turn with downloads and removals, so a removal queued before it goes first.
    private func startLoad() {
        generation += 1
        let generation = generation
        state = .loading
        let previous = lastOperation
        lastOperation = Task {
            await previous?.value
            guard generation == self.generation else { return }
            await load(generation: generation)
        }
    }

    /// Deletes the model, its unfinished download, and any folder it was replacing. A download in
    /// progress is cancelled first, and a load in progress is let finish without becoming ready; the
    /// folders go once they have stopped. The model shows as not downloaded at once, so nothing can
    /// start loading it meanwhile.
    func remove() {
        if case .downloading = state { cancelDownload() }

        generation += 1
        let generation = generation
        if state != .unsupported { state = .notDownloaded }
        removeReplacedDirectory()
        let previous = lastOperation
        // An accepted Delete always removes the files, even if a later Download, which waits its turn
        // behind it, has changed what the state should show; only that state update is skipped.
        lastOperation = Task {
            await previous?.value
            await operations.unload()
            var removed = true
            for folder in [directory, Self.stagingDirectory(for: directory)]
            where fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
                do {
                    try fileManager.removeItem(at: folder)
                } catch {
                    removed = false
                    break
                }
            }
            guard generation == self.generation, state != .unsupported else { return }
            state = removed ? .notDownloaded : .failed("Couldn't remove the model.")
        }
    }

    /// Waits until every queued download, load, and removal has finished, including any queued
    /// meanwhile.
    func waitUntilIdle() async {
        while let operation = lastOperation {
            await operation.value
            if lastOperation == operation { return }
        }
    }

    private func removeReplacedDirectory() {
        guard let replacedDirectory else { return }
        self.replacedDirectory = nil
        try? fileManager.removeItem(at: replacedDirectory)
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
