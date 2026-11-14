import Foundation

protocol TextTransformer: Sendable {
    func transform(_ text: String, instruction: String) async throws -> String
}

protocol StreamingTextTransformer: TextTransformer {
    /// Yields append-only text fragments and then finishes.
    func transformStream(
        _ text: String,
        instruction: String
    ) -> AsyncThrowingStream<String, any Error>

    /// Starts a clean atomic generation after a stream cannot remain append-only.
    func transformAfterStreamingFallback(
        _ text: String,
        instruction: String
    ) async throws -> String
}

extension StreamingTextTransformer {
    func transformAfterStreamingFallback(
        _ text: String,
        instruction: String
    ) async throws -> String {
        try await transform(text, instruction: instruction)
    }
}

/// Freezes a provider's configuration for one run. Settings edits after the trigger never reach
/// a run that already took its snapshot.
protocol TransformerSnapshotting: Sendable {
    @MainActor func snapshot(for provider: TranslationProvider) -> TransformerSnapshot
}

/// One run's provider configuration. It builds transformers for that run's instructions only.
struct TransformerSnapshot: Sendable {
    /// Pause transformation may send not-yet-final input only to providers that stay on this Mac.
    let permitsUnfinalizedInput: Bool
    private let make: @Sendable (String) async -> any TextTransformer

    init(
        permitsUnfinalizedInput: Bool = false,
        make: @escaping @Sendable (_ instruction: String) async -> any TextTransformer
    ) {
        self.permitsUnfinalizedInput = permitsUnfinalizedInput
        self.make = make
    }

    static func fixed(_ transformer: any TextTransformer) -> TransformerSnapshot {
        TransformerSnapshot { _ in transformer }
    }

    static func failed(_ error: any Error) -> TransformerSnapshot {
        fixed(FailedTextTransformer(error: error))
    }

    func transformer(instruction: String) async -> any TextTransformer {
        await make(instruction)
    }
}

/// A transformer source with no configuration to freeze, such as a fixed transformer or a test fake.
/// Its snapshot asks the source again for each transformer.
protocol TransformerSource: TransformerSnapshotting {
    func transformer(for provider: TranslationProvider, instruction: String) async -> any TextTransformer
}

extension TransformerSource {
    @MainActor func snapshot(for provider: TranslationProvider) -> TransformerSnapshot {
        TransformerSnapshot { [self] instruction in
            await transformer(for: provider, instruction: instruction)
        }
    }
}

struct FailedTextTransformer: TextTransformer {
    let error: any Error
    func transform(_ text: String, instruction: String) async throws -> String { throw error }
}

struct StaticTransformerProvider: TransformerSource {
    let transformer: any TextTransformer

    func transformer(
        for provider: TranslationProvider,
        instruction: String
    ) async -> any TextTransformer {
        transformer
    }
}

final class AppSettingsTransformerProvider: TransformerSnapshotting {
    private let session: URLSession
    private let environment: [String: String]
    private let settings: AppSettings
    private let keychainStore: KeychainStore
    private let injectedOpenAI: (any TextTransformer)?
    private let injectedCodex: (any TextTransformer)?
    private let appleOnDeviceFactory: @Sendable (String) -> any TextTransformer

    init(
        settings: AppSettings,
        keychainStore: KeychainStore,
        session: URLSession = .shared,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        openAICompatibleTransformer: (any TextTransformer)? = nil,
        codexCLITransformer: (any TextTransformer)? = nil,
        appleOnDeviceFactory: @escaping @Sendable (String) -> any TextTransformer = {
            AppleOnDeviceTransformer(instruction: $0, shouldPrewarm: true)
        }
    ) {
        self.session = session
        self.environment = environment
        self.settings = settings
        self.keychainStore = keychainStore
        injectedOpenAI = openAICompatibleTransformer
        injectedCodex = codexCLITransformer
        self.appleOnDeviceFactory = appleOnDeviceFactory
    }

    @MainActor
    func snapshot(for provider: TranslationProvider) -> TransformerSnapshot {
        do {
            switch provider {
            case .appleOnDevice:
                return TransformerSnapshot(permitsUnfinalizedInput: true, make: appleOnDeviceFactory)
            case .openAICompatible:
                if let injectedOpenAI { return .fixed(injectedOpenAI) }
                let configuration = try openAICompatibleConfiguration()
                let session = session
                return TransformerSnapshot(
                    permitsUnfinalizedInput: EndpointPolicy.isLoopback(configuration.baseURL)
                ) { _ in
                    OpenAICompatibleTransformer(configuration: configuration, session: session)
                }
            case .codexCLI:
                if let injectedCodex { return .fixed(injectedCodex) }
                let configuration = try CodexCLIConfigurationResolver.configuration(
                    configuredPath: settings.codexPath, modelName: settings.codexModel, environment: environment
                )
                return .fixed(CodexCLITransformer(configuration: configuration))
            }
        } catch {
            return .failed(error)
        }
    }

    /// The configuration a run uses, through the same resolver as Settings' connection test.
    /// It reads the small key file synchronously at trigger time (measured in microseconds).
    @MainActor
    func openAICompatibleConfiguration() throws -> OpenAICompatibleConfiguration {
        try OpenAICompatibleSettingsConfigurationResolver.configuration(
            baseURLString: settings.baseURL,
            modelName: settings.modelName,
            savedAPIKey: keychainStore.load() ?? "",
            environment: environment
        )
    }
}
