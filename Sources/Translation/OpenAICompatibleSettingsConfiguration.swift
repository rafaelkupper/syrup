import Foundation

struct OpenAICompatibleSettingsConfigurationResolver: Sendable {
    static func configuration(
        baseURLString: String,
        modelName: String,
        typedAPIKey: String = "",
        keychainStore: KeychainStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> OpenAICompatibleConfiguration {
        let trimmedTypedAPIKey = typedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTypedAPIKey.isEmpty == false {
            return try OpenAICompatibleConfiguration.userSettings(
                baseURLString: baseURLString,
                apiKey: trimmedTypedAPIKey,
                modelName: modelName
            )
        }

        let savedAPIKey = try await Task.detached(priority: .userInitiated) { [keychainStore] in
            try keychainStore.load() ?? ""
        }.value

        if savedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return try OpenAICompatibleConfiguration.userSettings(
                baseURLString: baseURLString,
                apiKey: savedAPIKey,
                modelName: modelName
            )
        }

        if let environmentConfiguration = try? OpenAICompatibleConfiguration.environment(environment) {
            return environmentConfiguration
        }

        return try OpenAICompatibleConfiguration.userSettings(
            baseURLString: baseURLString,
            apiKey: "",
            modelName: modelName
        )
    }
}

final class AppSettingsOpenAICompatibleConfigurationProvider: OpenAICompatibleConfigurationProviding, @unchecked Sendable {
    private struct EndpointSettings: Sendable {
        let baseURL: String
        let modelName: String
    }

    private let settings: AppSettings
    private let keychainStore: KeychainStore
    private let environment: [String: String]

    init(
        settings: AppSettings,
        keychainStore: KeychainStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.settings = settings
        self.keychainStore = keychainStore
        self.environment = environment
    }

    func configuration() async throws -> OpenAICompatibleConfiguration {
        let endpointSettings = await MainActor.run {
            EndpointSettings(
                baseURL: settings.baseURL,
                modelName: settings.modelName
            )
        }
        return try await OpenAICompatibleSettingsConfigurationResolver.configuration(
            baseURLString: endpointSettings.baseURL,
            modelName: endpointSettings.modelName,
            keychainStore: keychainStore,
            environment: environment
        )
    }
}
