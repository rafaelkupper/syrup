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

/// The comparison model for glossary learning: Whisper large-v3 from `argmaxinc/whisperkit-coreml`,
/// and its tokenizer from `openai/whisper-large-v3`, both kept under `Application Support/Syrup/
/// WhisperModels/` in WhisperKit's own layout. The published model folder holds no tokenizer, and
/// WhisperKit fetches one at load time into `~/Documents/huggingface` unless told where it is, so
/// Syrup fetches it with the model and passes that folder (`tokenizerBase`) to every load.
@MainActor
@Observable
final class WhisperModelManager: WhisperModelManaging {
    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    /// The network side, so tests stand in for Hugging Face with the published layout.
    struct Operations: Sendable {
        /// Fetches the model into `base`, in WhisperKit's layout (`modelFolder(in:)`).
        var downloadModel: @Sendable (_ base: URL, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
        /// Fetches the tokenizer into `base`, in WhisperKit's hub layout (`tokenizerFolder(in:)`).
        var downloadTokenizer: @Sendable (_ base: URL) async throws -> Void

        static let live = Operations(
            downloadModel: { base, progress in
                _ = try await WhisperKit.download(variant: WhisperModelManager.modelVariant, downloadBase: base) { fraction in
                    progress(fraction.fractionCompleted)
                }
            },
            downloadTokenizer: { base in
                _ = try await ModelUtilities.loadTokenizer(for: .largev3, tokenizerFolder: base)
            }
        )
    }

    nonisolated static let modelVariant = "openai_whisper-large-v3-v20240930_626MB"
    /// What each model bundle needs before it counts: a download cut short can leave the folder.
    nonisolated static let bundleFiles = ["AudioEncoder", "MelSpectrogram", "TextDecoder"].flatMap { bundle in
        ["coremldata.bin", "weights/weight.bin"].map { "\(bundle).mlmodelc/\($0)" }
    }
    /// What WhisperKit's tokenizer fetch writes and its load reads.
    nonisolated static let tokenizerFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]

    private enum Failure {
        case download, load, removal
    }

    private(set) var state: State
    let storageDirectory: URL
    let modelDirectory: URL
    let tokenizerDirectory: URL
    /// Passed to WhisperKit as `tokenizerFolder`; it finds the tokenizer at `tokenizerDirectory`.
    var tokenizerBase: URL { storageDirectory }
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var failure: Failure?
    /// The latest download or removal. The next waits for it: both touch the same folders.
    @ObservationIgnored private var lastOperation: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    init(
        storageDirectory: URL? = nil,
        operations: Operations = .live,
        fileManager: FileManager = .default
    ) {
        let storageDirectory = storageDirectory ?? Self.defaultStorageDirectory(fileManager: fileManager)
        self.operations = operations
        self.fileManager = fileManager
        self.storageDirectory = storageDirectory
        modelDirectory = Self.modelFolder(in: storageDirectory)
        tokenizerDirectory = Self.tokenizerFolder(in: storageDirectory)
        state = Self.isComplete(Self.bundleFiles, in: modelDirectory, fileManager: fileManager)
            && Self.isComplete(Self.tokenizerFiles, in: tokenizerDirectory, fileManager: fileManager)
            ? .ready : .notDownloaded
    }

    nonisolated static func modelFolder(in base: URL) -> URL {
        base.appending(path: "models/argmaxinc/whisperkit-coreml/\(modelVariant)", directoryHint: .isDirectory)
    }

    nonisolated static func tokenizerFolder(in base: URL) -> URL {
        base.appending(path: "models/openai/whisper-large-v3", directoryHint: .isDirectory)
    }

    /// Downloads what is missing and waits for it. A learning pass that is cancelled, because the
    /// person started dictating, cancels a download it started. One already under way, started from
    /// Settings, is left to finish, and the pass does not wait for it.
    func ensureModel() async {
        guard failure != .load else { return }
        switch state {
        case .ready, .downloading:
            return
        case .notDownloaded, .failed:
            break
        }
        let task = startDownload()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Settings' Cancel, and turning learning off: stops the download and keeps nothing it fetched
    /// in place. What arrived stays in staging for a later download.
    func cancelDownload() {
        guard case .downloading = state else { return }
        generation += 1
        downloadTask?.cancel()
        state = .notDownloaded
    }

    /// Settings' Retry, for whichever step failed. After a failed load the model on disk is not
    /// trusted, so it downloads again in full.
    func retry() async {
        switch failure {
        case .removal:
            removeModel()
            await waitUntilIdle()
        case .load:
            for folder in [modelDirectory, tokenizerDirectory] { try? fileManager.removeItem(at: folder) }
            failure = nil
            state = .notDownloaded
            await ensureModel()
        case .download, nil:
            failure = nil
            if state != .ready { state = .notDownloaded }
            await ensureModel()
        }
    }

    func modelFailedToLoad() {
        failure = .load
        state = .failed("The recognition model couldn't load. Retry downloads it again.")
    }

    /// Deletes the model and tokenizer. A download under way is cancelled first, and the files go
    /// once it has stopped; the model shows as not downloaded at once.
    func removeModel() {
        cancelDownload()
        generation += 1
        let generation = generation
        failure = nil
        state = .notDownloaded
        let previous = lastOperation
        lastOperation = Task {
            await previous?.value
            var removed = true
            if fileManager.fileExists(atPath: storageDirectory.path(percentEncoded: false)) {
                do {
                    try fileManager.removeItem(at: storageDirectory)
                } catch {
                    removed = false
                }
            }
            guard generation == self.generation, removed == false else { return }
            failure = .removal
            state = .failed("Couldn't remove the recognition model.")
        }
    }

    /// Waits until every queued download and removal has finished.
    func waitUntilIdle() async {
        while let operation = lastOperation {
            await operation.value
            if lastOperation == operation { return }
        }
    }

    private func startDownload() -> Task<Void, Never> {
        generation += 1
        let generation = generation
        failure = nil
        state = .downloading(0)
        let previous = lastOperation
        let task = Task {
            await previous?.value
            guard generation == self.generation else { return }
            await download(generation: generation)
        }
        downloadTask = task
        lastOperation = task
        return task
    }

    /// Into a staging folder, moved into place only when complete and not cancelled, so a download
    /// cut short by quitting, sleep, or Cancel never looks like a model. A model already complete on
    /// disk, as an earlier build left it, needs only the tokenizer.
    private func download(generation: Int) async {
        let staging = storageDirectory.appending(path: ".partial", directoryHint: .isDirectory)
        let stagedModel = Self.modelFolder(in: staging)
        let stagedTokenizer = Self.tokenizerFolder(in: staging)
        let hasModel = Self.isComplete(Self.bundleFiles, in: modelDirectory, fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            if hasModel == false {
                try await operations.downloadModel(staging) { [weak self] fraction in
                    Task { @MainActor in self?.updateDownloadProgress(fraction, generation: generation) }
                }
            }
            try await operations.downloadTokenizer(staging)
            try Task.checkCancellation()
            guard generation == self.generation else { return }
            guard hasModel || Self.isComplete(Self.bundleFiles, in: stagedModel, fileManager: fileManager),
                  Self.isComplete(Self.tokenizerFiles, in: stagedTokenizer, fileManager: fileManager)
            else {
                failure = .download
                state = .failed("Recognition model download failed.")
                return
            }
            if hasModel == false { try replace(modelDirectory, with: stagedModel) }
            try replace(tokenizerDirectory, with: stagedTokenizer)
            try? fileManager.removeItem(at: staging)
            state = .ready
        } catch {
            guard generation == self.generation else { return }
            // A cancelled request can surface as a URL error rather than CancellationError.
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                state = .notDownloaded
            } else {
                failure = .download
                state = .failed("Recognition model download failed.")
            }
        }
    }

    private func replace(_ destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: source, to: destination)
    }

    private static func isComplete(_ files: [String], in folder: URL, fileManager: FileManager) -> Bool {
        files.allSatisfy { fileManager.fileExists(atPath: folder.appending(path: $0).path(percentEncoded: false)) }
    }

    private func updateDownloadProgress(_ progress: Double, generation: Int) {
        guard generation == self.generation, case .downloading = state else { return }
        state = .downloading(min(max(progress, 0), 1))
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL {
        let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return baseURL
            .appending(path: "Syrup", directoryHint: .isDirectory)
            .appending(path: "WhisperModels", directoryHint: .isDirectory)
    }
}
