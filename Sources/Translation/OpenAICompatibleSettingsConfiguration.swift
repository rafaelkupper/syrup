import Foundation

/// The single precedence rule for OpenAI-compatible settings, shared by runs, the onboarding check,
/// and Settings' connection test: a typed key, then the saved key, then (Debug builds only) a complete
/// `OPENAI_COMPATIBLE_*` environment configuration, then the saved endpoint with no key. Keys are
/// compared after trimming. A saved key that cannot be read is an error and never falls back.
enum OpenAICompatibleSettingsConfigurationResolver {
    /// The environment fallback is a development aid for `script/launch_syrup_with_env.sh`. A Release
    /// build ignores it, so what Settings shows is always what a run uses.
    static var allowsEnvironmentFallback: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func configuration(
        baseURLString: String,
        modelName: String,
        typedAPIKey: String = "",
        savedAPIKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowsEnvironmentFallback: Bool = Self.allowsEnvironmentFallback
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

        if allowsEnvironmentFallback,
           let environmentConfiguration = try? OpenAICompatibleConfiguration.environment(environment) {
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
