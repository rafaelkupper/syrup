import Foundation
import WhisperKit
import Synchronization

protocol BatchTranscribing: Sendable {
    /// Transcribes a whole audio file. languageCode is a bare ISO 639-1 subtag ("pt").
    func transcribe(fileURL: URL, languageCode: String) async throws -> String
    /// Releases the model working set after an idle-time processing pass.
    func releaseModels() async
}

actor WhisperKitBatchTranscriber: BatchTranscribing {
    private let modelDirectory: URL
    private var pipeline: WhisperKit?

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func transcribe(fileURL: URL, languageCode: String) async throws -> String {
        let cancelled = Mutex(false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let pipeline = try await loadedPipeline()
            try Task.checkCancellation()
            let results = try await pipeline.transcribe(
                audioPath: fileURL.path,
                decodeOptions: DecodingOptions(language: languageCode),
                callback: { _ in cancelled.withLock { $0 } ? false : nil }
            )
            try Task.checkCancellation()
            return results.map(\.text).joined(separator: " ")
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    func releaseModels() async {
        await pipeline?.unloadModels()
        pipeline = nil
    }

    private func loadedPipeline() async throws -> WhisperKit {
        if let pipeline {
            return pipeline
        }

        let pipeline = try await WhisperKit(WhisperKitConfig(
            model: WhisperModelManager.modelVariant,
            modelFolder: modelDirectory.path,
            verbose: false,
            load: true,
            download: false
        ))
        self.pipeline = pipeline
        return pipeline
    }
}
