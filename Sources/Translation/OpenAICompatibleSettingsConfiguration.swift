import Foundation

/// The single precedence rule for OpenAI-compatible settings, shared by runs, the onboarding check,
/// and Settings' connection test: a typed key, then the saved key, then a complete environment
/// configuration, then the saved endpoint with no key. Keys are compared after trimming. A saved
/// key that cannot be read is an error and never falls back to the environment.
enum OpenAICompatibleSettingsConfigurationResolver {
    static func configuration(
        baseURLString: String,
        modelName: String,
        typedAPIKey: String = "",
        savedAPIKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> OpenAICompatibleConfiguration {
        for key in [typedAPIKey, savedAPIKey] {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                return try OpenAICompatibleConfiguration.userSettings(
                    baseURLString: baseURLString,
                    apiKey: trimmed,
                    modelName: modelName
                )
            }
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

    /// Reads the saved key off the main actor, then applies the same precedence.
    static func configuration(
        baseURLString: String,
        modelName: String,
        typedAPIKey: String = "",
        keychainStore: KeychainStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> OpenAICompatibleConfiguration {
        let trimmedTypedAPIKey = typedAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedAPIKey = trimmedTypedAPIKey.isEmpty
            ? try await Task.detached(priority: .userInitiated) { [keychainStore] in
                try keychainStore.load() ?? ""
            }.value
            : ""
        return try configuration(
            baseURLString: baseURLString,
            modelName: modelName,
            typedAPIKey: trimmedTypedAPIKey,
            savedAPIKey: savedAPIKey,
            environment: environment
        )
    }
}
