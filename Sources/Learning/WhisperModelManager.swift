import Foundation
import Observation
import WhisperKit

@MainActor
protocol WhisperModelManaging: AnyObject, Sendable {
    var state: WhisperModelManager.State { get }
    func ensureModel() async
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
            let downloadedDirectory = try await WhisperKit.download(
                variant: Self.modelVariant,
                downloadBase: storageDirectory
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.updateDownloadProgress(
                        progress.fractionCompleted,
                        generation: generation
                    )
                }
            }
            guard downloadedDirectory.standardizedFileURL == modelDirectory.standardizedFileURL else {
                state = .failed("The recognition model was saved in an unexpected location.")
                return
            }
            state = .ready
        } catch is CancellationError {
            state = .notDownloaded
        } catch {
            state = .failed("Recognition model download failed.")
        }
    }

    /// Deletes the downloaded model files. Ignored while a download is in
    /// flight; a later download recreates the directory.
    func removeModel() {
        if case .downloading = state { return }

        downloadGeneration += 1
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

    private static func hasDownloadedModel(at url: URL, fileManager: FileManager) -> Bool {
        let requiredModels = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let hasRequiredModels = requiredModels.allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { pathExtension in
                let modelURL = url.appending(path: "\(name).\(pathExtension)")
                return fileManager.fileExists(atPath: modelURL.path(percentEncoded: false))
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
