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

protocol TransformerProviding: Sendable {
    var permitsUnfinalizedInput: Bool { get }
    @MainActor func snapshot(for provider: TranslationProvider) -> any TransformerProviding
    func transformer(
        for provider: TranslationProvider,
        instruction: String
    ) async -> any TextTransformer
}

extension TransformerProviding {
    var permitsUnfinalizedInput: Bool { false }
    @MainActor func snapshot(for provider: TranslationProvider) -> any TransformerProviding { self }
}

struct FailedTextTransformer: TextTransformer {
    let error: any Error
    func transform(_ text: String, instruction: String) async throws -> String { throw error }
}

struct StaticTransformerProvider: TransformerProviding {
    let transformer: any TextTransformer

    func transformer(
        for provider: TranslationProvider,
        instruction: String
    ) async -> any TextTransformer {
        transformer
    }
}

final class AppSettingsTransformerProvider: TransformerProviding, @unchecked Sendable {
    private let session: URLSession
    private let environment: [String: String]
    private let settings: AppSettings
    private let keychainStore: KeychainStore
    private let hasInjectedOpenAI: Bool
    private let hasInjectedCodex: Bool
    private let openAICompatibleTransformer: any TextTransformer
    private let codexCLITransformer: any TextTransformer
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
        hasInjectedOpenAI = openAICompatibleTransformer != nil
        hasInjectedCodex = codexCLITransformer != nil
        self.openAICompatibleTransformer = openAICompatibleTransformer ?? OpenAICompatibleTransformer(
            configurationProvider: AppSettingsOpenAICompatibleConfigurationProvider(
                settings: settings,
                keychainStore: keychainStore
            )
        )
        self.codexCLITransformer = codexCLITransformer ?? CodexCLITransformer(
            configurationProvider: AppSettingsCodexCLIConfigurationProvider(settings: settings)
        )
        self.appleOnDeviceFactory = appleOnDeviceFactory
    }

    @MainActor
    func snapshot(for provider: TranslationProvider) -> any TransformerProviding {
        do {
            let transformer: any TextTransformer
            switch provider {
            case .appleOnDevice:
                return OnDeviceTransformerProvider(factory: appleOnDeviceFactory)
            case .openAICompatible:
                if hasInjectedOpenAI { return StaticTransformerProvider(transformer: openAICompatibleTransformer) }
                let savedKey = try keychainStore.load() ?? ""
                let configuration: OpenAICompatibleConfiguration
                if savedKey.isEmpty, let environment = try? OpenAICompatibleConfiguration.environment(environment) {
                    configuration = environment
                } else {
                    configuration = try .userSettings(
                        baseURLString: settings.baseURL, apiKey: savedKey, modelName: settings.modelName
                    )
                }
                return ConfiguredOpenAITransformerProvider(configuration: configuration, session: session)
            case .codexCLI:
                if hasInjectedCodex { return StaticTransformerProvider(transformer: codexCLITransformer) }
                let configuration = try CodexCLIConfigurationResolver.configuration(
                    configuredPath: settings.codexPath, modelName: settings.codexModel
                )
                transformer = CodexCLITransformer(configuration: configuration)
            }
            return StaticTransformerProvider(transformer: transformer)
        } catch {
            return StaticTransformerProvider(transformer: FailedTextTransformer(error: error))
        }
    }

    func transformer(
        for provider: TranslationProvider,
        instruction: String
    ) async -> any TextTransformer {
        switch provider {
        case .openAICompatible:
            return openAICompatibleTransformer
        case .codexCLI:
            return codexCLITransformer
        case .appleOnDevice:
            return appleOnDeviceFactory(instruction)
        }
    }
}

private struct OnDeviceTransformerProvider: TransformerProviding {
    let factory: @Sendable (String) -> any TextTransformer
    var permitsUnfinalizedInput: Bool { true }

    func transformer(for provider: TranslationProvider, instruction: String) async -> any TextTransformer {
        factory(instruction)
    }
}

private struct ConfiguredOpenAITransformerProvider: TransformerProviding {
    let configuration: OpenAICompatibleConfiguration
    let session: URLSession
    var permitsUnfinalizedInput: Bool { PauseTransformation.isLoopback(configuration.baseURL) }

    func transformer(for provider: TranslationProvider, instruction: String) async -> any TextTransformer {
        OpenAICompatibleTransformer(configuration: configuration, session: session)
    }
}
