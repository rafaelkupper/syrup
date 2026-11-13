import FluidAudio
import Foundation

enum ParakeetError: Error, Equatable {
    case notLoaded
    case incompleteDownload
}

/// One Parakeet TDT model. Ultra and Redux are post-trainings of v3 with the same decoding.
actor ParakeetEngine {
    enum Model: Sendable {
        case ultra
        case redux

        var version: AsrModelVersion {
            switch self {
            case .ultra: .ultra
            case .redux: .redux
            }
        }

        var repo: Repo {
            switch self {
            case .ultra: .parakeetUltra
            case .redux: .parakeetRedux
            }
        }
    }

    #if arch(arm64)
    static let isSupported = true
    #else
    static let isSupported = false
    #endif

    private let model: Model
    private var manager: AsrManager?

    init(model: Model) {
        self.model = model
        AppLogger.mirrorsToConsole = false
        AppLogger.minimumLevel = .fault
    }

    static func modelDirectory(in root: URL, model: Model) -> URL {
        root.appending(path: model.repo.folderName, directoryHint: .isDirectory)
    }

    static func modelsExist(at directory: URL, model: Model) -> Bool {
        AsrModels.modelsExist(at: directory, version: model.version)
    }

    /// Fetches the files only. `AsrModels.download` also compiles each model for the Neural
    /// Engine at the download path, and Syrup moves the files afterwards, so `load` compiles
    /// them once where they stay. For Redux that compile took minutes.
    /// Downloads into `root`, which holds the model's own folder, as the other models' downloads do.
    static func download(to root: URL, model: Model, progress: @escaping @Sendable (Double) -> Void) async throws {
        // FluidAudio reports the download as the first half of a download-and-compile.
        try await ModelHub.download(model.repo, to: root, progressHandler: {
            progress(min($0.fractionCompleted * 2, 1))
        })
        guard modelsExist(at: modelDirectory(in: root, model: model), model: model) else {
            throw ParakeetError.incompleteDownload
        }
    }

    func load(from directory: URL) async throws {
        guard manager == nil else { return }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(AsrModels.loadLocal(from: directory, version: model.version))
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
        self.manager = manager
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String {
        guard let manager else { throw ParakeetError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let language = languageCode.flatMap(Language.init(rawValue:))
        return try await manager.transcribe(samples, decoderState: &state, language: language).text
    }
}
