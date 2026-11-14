import Foundation

/// What the pipeline needs for one downloadable engine.
struct InstalledSpeechModel {
    let transcriber: any Transcriber
    let models: any SpeechModelProviding
}

/// Every downloadable speech model, each with its own folder and state.
@MainActor
final class SpeechModelCatalog {
    let managers: [SpeechEngine: SpeechModelManager]
    let installed: [SpeechEngine: InstalledSpeechModel]

    init(managers: [SpeechEngine: SpeechModelManager], transcribers: [SpeechEngine: any Transcriber]) {
        self.managers = managers
        installed = managers.reduce(into: [:]) { result, entry in
            guard let transcriber = transcribers[entry.key] else { return }
            result[entry.key] = InstalledSpeechModel(transcriber: transcriber, models: entry.value)
        }
    }

    func manager(for engine: SpeechEngine) -> SpeechModelManager? {
        managers[engine]
    }

    /// Ultra replaced Parakeet v3 after 0.9. Ultra downloads in place of a v3 download left by 0.9, so
    /// the workflows that chose v3 keep a model on this Mac. The v3 folder is removed only once Ultra is
    /// on disk: if the download fails, v3 stays, and its folder makes the next launch try again.
    func replaceRetiredParakeetV3() {
        guard let ultra = managers[.parakeetUltra] else { return }
        let retired = ultra.directory.deletingLastPathComponent()
            .appending(path: SpeechEngine.retiredParakeetV3Folder, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: retired.path(percentEncoded: false)) else { return }
        let removeRetired: @MainActor @Sendable () -> Void = { try? FileManager.default.removeItem(at: retired) }
        switch ultra.state {
        case .downloaded, .loading, .ready:
            removeRetired()
        case .notDownloaded, .failed:
            ultra.download(onDownloaded: removeRetired)
        case .downloading, .unsupported:
            break
        }
    }

    static func live(storageDirectory: URL? = nil) -> SpeechModelCatalog {
        let ultra = ParakeetEngine(model: .ultra)
        let redux = ParakeetEngine(model: .redux)
        let nemotron = StreamingSpeechEngine(backend: NemotronBackend())
        let unified = StreamingSpeechEngine(backend: ParakeetUnifiedBackend())
        let canary = CanaryEngine()
        let managers: [SpeechEngine: SpeechModelManager] = [
            .parakeetUltra: stagedManager(
                .parakeetUltra, storageDirectory: storageDirectory,
                modelsExist: { ParakeetEngine.modelsExist(at: $0, model: .ultra) },
                download: { try await ParakeetEngine.download(to: $0, model: .ultra, progress: $1) },
                load: { try await ultra.load(from: $0) },
                unload: { await ultra.unload() }
            ),
            .parakeetRedux: stagedManager(
                .parakeetRedux, storageDirectory: storageDirectory,
                modelsExist: { ParakeetEngine.modelsExist(at: $0, model: .redux) },
                download: { try await ParakeetEngine.download(to: $0, model: .redux, progress: $1) },
                load: { try await redux.load(from: $0) },
                unload: { await redux.unload() }
            ),
            .nemotronStreaming: stagedManager(
                .nemotronStreaming, engine: nemotron, storageDirectory: storageDirectory,
                modelsExist: { NemotronBackend.modelsExist(at: $0) },
                download: { try await NemotronBackend.download(to: $0, progress: $1) }
            ),
            .parakeetUnifiedEN: stagedManager(
                .parakeetUnifiedEN, engine: unified, storageDirectory: storageDirectory,
                modelsExist: { ParakeetUnifiedBackend.modelsExist(at: $0) },
                download: { try await ParakeetUnifiedBackend.download(to: $0, progress: $1) }
            ),
            .canaryFlash: stagedManager(
                .canaryFlash, storageDirectory: storageDirectory,
                modelsExist: { CanaryModel.isComplete(at: $0) },
                download: { try await CanaryModel.download(to: $0, progress: $1) },
                load: { try await canary.load(from: $0) },
                unload: { await canary.unload() }
            ),
        ]
        return SpeechModelCatalog(managers: managers, transcribers: [
            .parakeetUltra: ParakeetTranscriber(decoder: ultra),
            .parakeetRedux: ParakeetTranscriber(decoder: redux),
            .nemotronStreaming: StreamingTranscriber(engine: nemotron),
            .parakeetUnifiedEN: StreamingTranscriber(engine: unified),
            .canaryFlash: CanaryTranscriber(decoder: canary),
        ])
    }

    /// Downloads into a hidden folder and moves the finished model into place,
    /// so a model folder that exists is always complete.
    private static func stagedManager(
        _ speechEngine: SpeechEngine,
        engine: StreamingSpeechEngine,
        storageDirectory: URL?,
        modelsExist: @escaping @Sendable (URL) -> Bool,
        download: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    ) -> SpeechModelManager {
        stagedManager(
            speechEngine, storageDirectory: storageDirectory, modelsExist: modelsExist, download: download,
            load: { try await engine.load(from: $0) }, unload: { await engine.unload() }
        )
    }

    /// Downloads into a staging folder, then moves the finished model into place. A folder already at
    /// the destination is incomplete (a complete one would not be downloaded again), so it is replaced;
    /// otherwise the move would fail on every retry until the person chose Delete.
    static func stagedDownload(
        into directory: URL,
        modelsExist: @Sendable (URL) -> Bool,
        download: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let staging = SpeechModelManager.stagingDirectory(for: directory)
        try await download(staging, progress)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path(percentEncoded: false)), modelsExist(directory) == false {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.moveItem(
            at: staging.appending(path: directory.lastPathComponent, directoryHint: .isDirectory),
            to: directory
        )
        try fileManager.removeItem(at: staging)
    }

    private static func stagedManager(
        _ speechEngine: SpeechEngine,
        storageDirectory: URL?,
        modelsExist: @escaping @Sendable (URL) -> Bool,
        download: @escaping @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void,
        load: @escaping @Sendable (URL) async throws -> Void,
        unload: @escaping @Sendable () async -> Void
    ) -> SpeechModelManager {
        SpeechModelManager(
            engine: speechEngine,
            operations: .init(
                modelsExist: modelsExist,
                download: { directory, progress in
                    try await stagedDownload(into: directory, modelsExist: modelsExist, download: download, progress: progress)
                },
                load: load,
                unload: unload
            ),
            isSupported: ParakeetEngine.isSupported,
            storageDirectory: storageDirectory
        )
    }
}
