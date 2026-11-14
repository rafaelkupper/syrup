import Foundation
import Observation
import WhisperKit

@MainActor
protocol WhisperModelManaging: AnyObject, Sendable {
    var state: WhisperModelManager.State { get }
    /// Downloads the model if it is missing. Learning passes call it; it does nothing after the
    /// model on disk failed to load, until the person retries or removes it.
    func ensureModel() async
    /// The model on disk failed to load: it is marked failed, and passes stop using it.
    func modelFailedToLoad()
}

@MainActor
@Observable
final class WhisperModelManager: WhisperModelManaging {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    static let modelVariant = "openai_whisper-large-v3-v20240930_626MB"

    private(set) var state: State
    let storageDirectory: URL
    let modelDirectory: URL
    private let fileManager: FileManager
    private var downloadGeneration = 0
    /// Set when the model on disk failed to load, so background passes do not download it again on
    /// their own; the person chooses Retry or Delete.
    private var failedToLoad = false

    init(
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let storageDirectory = storageDirectory
            ?? Self.defaultStorageDirectory(fileManager: fileManager)
        self.fileManager = fileManager
        self.storageDirectory = storageDirectory
        self.modelDirectory = storageDirectory
            .appending(path: "models", directoryHint: .isDirectory)
            .appending(path: "argmaxinc", directoryHint: .isDirectory)
            .appending(path: "whisperkit-coreml", directoryHint: .isDirectory)
            .appending(path: Self.modelVariant, directoryHint: .isDirectory)
        self.state = Self.hasDownloadedModel(
            at: self.modelDirectory,
            fileManager: fileManager
        ) ? .ready : .notDownloaded
    }

    func ensureModel() async {
        guard failedToLoad == false else { return }
        switch state {
        case .ready, .downloading:
            return
        case .notDownloaded, .failed:
            break
        }

        downloadGeneration += 1
        let generation = downloadGeneration
        state = .downloading(0)
        do {
            // Into a staging folder, moved into place only when complete, so a download cut short by
            // quitting or sleep never looks like a model.
            let staging = storageDirectory.appending(path: ".partial", directoryHint: .isDirectory)
            let downloadedDirectory = try await WhisperKit.download(
                variant: Self.modelVariant,
                downloadBase: staging
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.updateDownloadProgress(
                        progress.fractionCompleted,
                        generation: generation
                    )
                }
            }
            guard Self.hasDownloadedModel(at: downloadedDirectory, fileManager: fileManager) else {
                state = .failed("Recognition model download failed.")
                return
            }
            if fileManager.fileExists(atPath: modelDirectory.path(percentEncoded: false)) {
                try fileManager.removeItem(at: modelDirectory)
            }
            try fileManager.createDirectory(at: modelDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.moveItem(at: downloadedDirectory, to: modelDirectory)
            try? fileManager.removeItem(at: staging)
            state = .ready
        } catch is CancellationError {
            state = .notDownloaded
        } catch {
            state = .failed("Recognition model download failed.")
        }
    }

    /// Settings' Retry: downloads again even after the model failed to load.
    func retryDownload() async {
        failedToLoad = false
        if state == .ready { state = .notDownloaded }
        await ensureModel()
    }

    func modelFailedToLoad() {
        failedToLoad = true
        state = .failed("The recognition model couldn't load. Retry downloads it again.")
    }

    /// Deletes the downloaded model files. Ignored while a download is in
    /// flight; a later download recreates the directory.
    func removeModel() {
        if case .downloading = state { return }

        downloadGeneration += 1
        failedToLoad = false
        let path = storageDirectory.path(percentEncoded: false)
        if fileManager.fileExists(atPath: path) {
            do {
                try fileManager.removeItem(at: storageDirectory)
            } catch {
                state = .failed("Couldn't remove the recognition model.")
                return
            }
        }
        state = .notDownloaded
    }

    /// Each model counts once its compiled `coremldata.bin`, or an uncompiled package's
    /// `Manifest.json`, is there, not merely its folder: a download cut short leaves the folder.
    private static func hasDownloadedModel(at url: URL, fileManager: FileManager) -> Bool {
        let requiredModels = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let hasRequiredModels = requiredModels.allSatisfy { name in
            [("mlmodelc", "coremldata.bin"), ("mlpackage", "Manifest.json")].contains { pathExtension, marker in
                let markerURL = url.appending(path: "\(name).\(pathExtension)").appending(path: marker)
                return fileManager.fileExists(atPath: markerURL.path(percentEncoded: false))
            }
        }
        let tokenizerURL = url.appending(path: "tokenizer.json")
        return hasRequiredModels
            && fileManager.fileExists(atPath: tokenizerURL.path(percentEncoded: false))
    }

    private func updateDownloadProgress(_ progress: Double, generation: Int) {
        guard generation == downloadGeneration, case .downloading = state else { return }
        state = .downloading(Self.normalized(progress))
    }

    private static func normalized(_ progress: Double) -> Double {
        min(max(progress, 0), 1)
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return baseURL
            .appending(path: "Syrup", directoryHint: .isDirectory)
            .appending(path: "WhisperModels", directoryHint: .isDirectory)
    }
}
