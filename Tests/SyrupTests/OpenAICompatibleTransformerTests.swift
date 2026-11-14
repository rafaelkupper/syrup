import Foundation
import Testing
@testable import Syrup

@Suite(.serialized)
struct OpenAICompatibleTransformerTests {
    @Test(arguments: [false, true])
    func requestedQuotesSurviveAtomicAndJSONStreamResponses(streaming: Bool) async throws {
        let session = Self.stubbedSession { _ in
            let (response, body) = Self.response(statusCode: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"\"hello\""}}]}"#)
            return (HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, body)
        }
        defer { StubURLProtocol.reset() }
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )
        let instruction = PromptBuilder.spokenFormattingInstruction
        let output: String
        if streaming {
            var streamed = ""
            for try await delta in transformer.transformStream("In quotes hello.", instruction: instruction) {
                streamed += delta
            }
            output = streamed
        } else {
            output = try await transformer.transform("In quotes hello.", instruction: instruction)
        }
        #expect(output == #""hello""#)
    }

    @Test
    func anAtomicResponseLargerThanTheLimitIsRejected() async throws {
        let session = Self.stubbedSession { _ in
            let padding = String(repeating: "a", count: OpenAICompatibleTransformer.responseBodyLimit + 1_024)
            return Self.response(statusCode: 200, body: #"{"choices":[{"message":{"role":"assistant","content":""# + padding + #""}}]}"#)
        }
        defer { StubURLProtocol.reset() }
        let transformer = OpenAICompatibleTransformer(configuration: try Self.configuration(), session: session)
        await #expect(throws: TranslationError.responseTooLarge) {
            _ = try await transformer.transform("hello", instruction: "Polish it.")
        }
    }

    /// Headers and body each arrive within the timeout, but together they take longer: one deadline
    /// covers both, so the request still times out.
    @Test
    func aReplyWhoseHeadersAndBodyTogetherTakeTooLongTimesOut() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowURLProtocol.self]
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(), session: URLSession(configuration: configuration),
            timeoutInterval: 1
        )
        await #expect(throws: TranslationError.timedOut) {
            _ = try await transformer.transform("hello", instruction: "Polish it.")
        }
    }

    @Test
    func chatCompletionsURLAppendsPathAfterStoredV1BaseURL() throws {
        let noSlashURL = try OpenAICompatibleTransformer.chatCompletionsURL(
            baseURL: try #require(URL(string: "https://example.com/v1"))
        )
        let slashURL = try OpenAICompatibleTransformer.chatCompletionsURL(
            baseURL: try #require(URL(string: "https://example.com/v1/"))
        )

        #expect(noSlashURL.absoluteString == "https://example.com/v1/chat/completions")
        #expect(slashURL.absoluteString == "https://example.com/v1/chat/completions")
    }

    @Test
    func requestUsesConfiguredURLHeadersAndBody() async throws {
        let session = Self.stubbedSession { request in
            #expect(request.url?.absoluteString == "https://example.com/v1/chat/completions")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")

            let body = try Self.jsonBody(from: request)
            #expect(body["model"] as? String == "tiny-model")
            #expect(body["temperature"] as? Double == 0.3)
            #expect(body["max_tokens"] == nil)

            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages.count == 2)
            #expect(messages[0]["role"] == "system")
            #expect(messages[0]["content"]?.contains("Translate to English.") == true)
            #expect(messages[0]["content"]?.contains("Use a professional tone.") == true)
            #expect(messages[1] == ["role": "user", "content": "bom dia"])

            return Self.response(statusCode: 200, body: """
            {
              "choices": [
                { "message": { "role": "assistant", "content": "Good morning" } }
              ],
              "usage": { "prompt_tokens": 12, "completion_tokens": 3, "total_tokens": 15 }
            }
            """)
        }
        defer { StubURLProtocol.reset() }

        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(apiKey: "test-key"),
            session: session
        )
        let result = try await transformer.transformWithUsage(
            "bom dia",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "Use a professional tone.")
        )

        #expect(result.text == "Good morning")
        #expect(result.usage == OpenAICompatibleTokenUsage(promptTokens: 12, completionTokens: 3, totalTokens: 15))
    }

    @Test
    func streamingRequestSetsStreamAndYieldsSSEDeltas() async throws {
        let session = Self.stubbedSession { request in
            let body = try Self.jsonBody(from: request)
            #expect(body["stream"] as? Bool == true)
            #expect(body["model"] as? String == "tiny-model")

            return Self.response(statusCode: 200, body: """
            data: {"choices":[{"delta":{"role":"assistant"}}]}

            data: {"choices":[{"delta":{"content":"Good"}}]}

            data: {"choices":[{"delta":{"content":" morning"}}]}

            data: [DONE]

            """)
        }
        defer { StubURLProtocol.reset() }
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )

        var deltas: [String] = []
        for try await delta in transformer.transformStream(
            "bom dia",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
        ) {
            deltas.append(delta)
        }

        #expect(deltas == ["Good", " morning"])
    }

    @Test
    func streamingHTTPErrorUsesExistingMapping() async throws {
        let session = Self.stubbedSession { _ in
            Self.response(statusCode: 429, body: #"{"error":"limited"}"#)
        }
        defer { StubURLProtocol.reset() }
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )

        await #expect(throws: TranslationError.rateLimited) {
            for try await _ in transformer.transformStream(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            ) {}
        }
    }

    @Test
    func malformedMidStreamEventSurfacesAfterEarlierDelta() async throws {
        let session = Self.stubbedSession { _ in
            Self.response(statusCode: 200, body: """
            data: {"choices":[{"delta":{"content":"Good"}}]}

            data: {not-json}

            """)
        }
        defer { StubURLProtocol.reset() }
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )
        var deltas: [String] = []

        do {
            for try await delta in transformer.transformStream(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            ) {
                deltas.append(delta)
            }
            Issue.record("Expected malformed SSE data to fail the stream")
        } catch TranslationError.invalidResponse {
            #expect(deltas == ["Good"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func endpointTesterOmitsMaxTokensForOpenRouterCompatibility() async throws {
        let session = Self.stubbedSession { request in
            let body = try Self.jsonBody(from: request)
            #expect(body["model"] as? String == "tiny-model")
            #expect(body["max_tokens"] == nil)

            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages.last == ["role": "user", "content": "hi"])

            return Self.response(statusCode: 200, body: """
            {
              "choices": [
                { "message": { "role": "assistant", "content": "OK" } }
              ],
              "usage": { "prompt_tokens": 8, "completion_tokens": 1, "total_tokens": 9 }
            }
            """)
        }
        defer { StubURLProtocol.reset() }

        let tester = OpenAICompatibleEndpointTester(session: session)

        try await tester.testConnection(configuration: try Self.configuration())
    }

    @Test
    func emptyAPIKeyOmitsAuthorizationHeader() async throws {
        let session = Self.stubbedSession { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return Self.response(statusCode: 200, body: """
            {
              "choices": [
                { "message": { "role": "assistant", "content": "Good morning" } }
              ]
            }
            """)
        }
        defer { StubURLProtocol.reset() }

        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(apiKey: ""),
            session: session
        )

        let transformedText = try await transformer.transform(
            "bom dia",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
        )

        #expect(transformedText == "Good morning")
    }

    @Test
    func responseIsTrimmedAndMatchingQuotesAreStripped() async throws {
        let session = Self.stubbedSession { _ in
            Self.response(statusCode: 200, body: """
            {
              "choices": [
                { "message": { "role": "assistant", "content": "  \\\"Good morning\\\"  " } }
              ]
            }
            """)
        }
        defer { StubURLProtocol.reset() }

        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )

        let transformedText = try await transformer.transform(
            "bom dia",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
        )

        #expect(transformedText == "Good morning")
    }

    @Test(arguments: [
        (401, TranslationError.apiKeyRejected),
        (429, TranslationError.rateLimited),
        (500, TranslationError.httpStatus(500))
    ])
    func httpErrorsAreMapped(statusCode: Int, expectedError: TranslationError) async throws {
        let session = Self.stubbedSession { _ in
            Self.response(statusCode: statusCode, body: #"{"error":"nope"}"#)
        }
        defer { StubURLProtocol.reset() }

        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )

        await #expect(throws: expectedError) {
            try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test
    func connectionErrorsIncludeHost() async throws {
        let session = Self.stubbedSession { _ in
            throw URLError(.cannotConnectToHost)
        }
        defer { StubURLProtocol.reset() }

        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )

        await #expect(throws: TranslationError.cannotConnect("example.com")) {
            try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test
    func timeoutErrorsAreMappedSeparatelyFromConnectivity() async throws {
        let session = Self.stubbedSession { _ in
            throw URLError(.timedOut)
        }
        defer { StubURLProtocol.reset() }

        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )

        await #expect(throws: TranslationError.timedOut) {
            try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test
    func nonTaskCancelledURLErrorCancelledMapsToConnectivity() async throws {
        let session = Self.stubbedSession { _ in
            throw URLError(.cancelled)
        }
        defer { StubURLProtocol.reset() }

        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )

        await #expect(throws: TranslationError.cannotConnect("example.com")) {
            try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test
    func missingChoicesThrowEmptyResponse() async throws {
        let session = Self.stubbedSession { _ in
            Self.response(statusCode: 200, body: #"{"choices":[]}"#)
        }
        defer { StubURLProtocol.reset() }

        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(),
            session: session
        )

        await #expect(throws: TranslationError.emptyResponse) {
            try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test
    func environmentConfigurationRequiresURLAPIKeyAndModel() {
        #expect(throws: TranslationError.missingConfiguration("OPENAI_COMPATIBLE_URL")) {
            try OpenAICompatibleConfiguration.environment([:])
        }

        #expect(throws: TranslationError.missingConfiguration("OPENAI_COMPATIBLE_API_KEY")) {
            try OpenAICompatibleConfiguration.environment([
                "OPENAI_COMPATIBLE_URL": "https://example.com/v1"
            ])
        }

        #expect(throws: TranslationError.missingConfiguration("OPENAI_COMPATIBLE_API_KEY")) {
            try OpenAICompatibleConfiguration.environment([
                "OPENAI_COMPATIBLE_URL": "https://example.com/v1",
                "OPENAI_COMPATIBLE_API_KEY": " "
            ])
        }

        #expect(throws: TranslationError.missingConfiguration("OPENAI_COMPATIBLE_MODEL")) {
            try OpenAICompatibleConfiguration.environment([
                "OPENAI_COMPATIBLE_URL": "https://example.com/v1",
                "OPENAI_COMPATIBLE_API_KEY": "test-key"
            ])
        }
    }

    @Test
    func userSettingsConfigurationTrimsValuesAndRejectsInvalidInput() throws {
        let configuration = try OpenAICompatibleConfiguration.userSettings(
            baseURLString: " https://example.com/v1/ ",
            apiKey: " test-key ",
            modelName: " tiny-model "
        )

        #expect(configuration.baseURL.absoluteString == "https://example.com/v1/")
        #expect(configuration.apiKey == "test-key")
        #expect(configuration.model == "tiny-model")

        #expect(throws: TranslationError.invalidBaseURL("example.com/v1")) {
            try OpenAICompatibleConfiguration.userSettings(
                baseURLString: "example.com/v1",
                apiKey: "",
                modelName: "tiny-model"
            )
        }

        #expect(throws: TranslationError.missingConfiguration("modelName")) {
            try OpenAICompatibleConfiguration.userSettings(
                baseURLString: "https://example.com/v1",
                apiKey: "",
                modelName: " "
            )
        }
    }

    @Test(arguments: [
        "example.com/v1",
        "ftp://example.com/v1"
    ])
    func environmentConfigurationRejectsNonHTTPBaseURLs(rawURL: String) {
        #expect(throws: TranslationError.invalidBaseURL(rawURL)) {
            try OpenAICompatibleConfiguration.environment([
                "OPENAI_COMPATIBLE_URL": rawURL,
                "OPENAI_COMPATIBLE_API_KEY": "test-key",
                "OPENAI_COMPATIBLE_MODEL": "tiny-model"
            ])
        }
    }

    @Test
    @MainActor
    func settingsResolverUsesTypedAPIKeyBeforeSavedKeyAndEnvironment() async throws {
        let (keychainStore, storageDirectory) = Self.temporaryKeychainStore()
        try? keychainStore.delete()
        defer {
            try? keychainStore.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }
        try keychainStore.save("saved-key")

        let configuration = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
            baseURLString: "https://settings.example/v1",
            modelName: "settings-model",
            typedAPIKey: " typed-key ",
            keychainStore: keychainStore,
            environment: [
                "OPENAI_COMPATIBLE_URL": "https://env.example/v1",
                "OPENAI_COMPATIBLE_API_KEY": "env-key",
                "OPENAI_COMPATIBLE_MODEL": "env-model"
            ]
        )

        #expect(configuration.baseURL.absoluteString == "https://settings.example/v1")
        #expect(configuration.apiKey == "typed-key")
        #expect(configuration.model == "settings-model")
    }

    @Test
    @MainActor
    func settingsResolverUsesSavedAPIKeyBeforeEnvironment() async throws {
        let (keychainStore, storageDirectory) = Self.temporaryKeychainStore()
        try? keychainStore.delete()
        defer {
            try? keychainStore.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }
        try keychainStore.save("saved-key")

        let configuration = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
            baseURLString: "https://settings.example/v1",
            modelName: "settings-model",
            keychainStore: keychainStore,
            environment: [
                "OPENAI_COMPATIBLE_URL": "https://env.example/v1",
                "OPENAI_COMPATIBLE_API_KEY": "env-key",
                "OPENAI_COMPATIBLE_MODEL": "env-model"
            ]
        )

        #expect(configuration.baseURL.absoluteString == "https://settings.example/v1")
        #expect(configuration.apiKey == "saved-key")
        #expect(configuration.model == "settings-model")
    }

    @Test
    @MainActor
    func settingsResolverFallsBackToCompleteEnvironmentWhenNoSavedAPIKeyExists() async throws {
        let (keychainStore, storageDirectory) = Self.temporaryKeychainStore()
        try? keychainStore.delete()
        defer {
            try? keychainStore.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        let configuration = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
            baseURLString: "https://settings.example/v1",
            modelName: "settings-model",
            keychainStore: keychainStore,
            environment: [
                "OPENAI_COMPATIBLE_URL": "https://env.example/v1",
                "OPENAI_COMPATIBLE_API_KEY": "env-key",
                "OPENAI_COMPATIBLE_MODEL": "env-model"
            ]
        )

        #expect(configuration.baseURL.absoluteString == "https://env.example/v1")
        #expect(configuration.apiKey == "env-key")
        #expect(configuration.model == "env-model")
    }

    /// A Release build ignores `OPENAI_COMPATIBLE_*`, so a run uses exactly what Settings shows.
    @Test
    func releaseBuildsIgnoreTheEnvironmentFallback() throws {
        let environment = [
            "OPENAI_COMPATIBLE_URL": "https://env.example/v1",
            "OPENAI_COMPATIBLE_API_KEY": "env-key",
            "OPENAI_COMPATIBLE_MODEL": "env-model",
        ]
        let release = try OpenAICompatibleSettingsConfigurationResolver.configuration(
            baseURLString: "https://settings.example/v1", modelName: "settings-model",
            savedAPIKey: "", environment: environment, allowsEnvironmentFallback: false
        )
        #expect(release == OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "https://settings.example/v1")), apiKey: "", model: "settings-model"
        ))
        let debug = try OpenAICompatibleSettingsConfigurationResolver.configuration(
            baseURLString: "https://settings.example/v1", modelName: "settings-model",
            savedAPIKey: "", environment: environment, allowsEnvironmentFallback: true
        )
        #expect(debug.model == "env-model")
        #expect(OpenAICompatibleSettingsConfigurationResolver.allowsEnvironmentFallback == Self.isDebugBuild)
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    @Test
    @MainActor
    func settingsResolverKeepsManualNoKeySettingsWhenEnvironmentIsIncomplete() async throws {
        let (keychainStore, storageDirectory) = Self.temporaryKeychainStore()
        try? keychainStore.delete()
        defer {
            try? keychainStore.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        let configuration = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
            baseURLString: "http://localhost:11434/v1",
            modelName: "settings-model",
            keychainStore: keychainStore,
            environment: [
                "OPENAI_COMPATIBLE_URL": "https://env.example/v1",
                "OPENAI_COMPATIBLE_API_KEY": " ",
                "OPENAI_COMPATIBLE_MODEL": "env-model"
            ]
        )

        #expect(configuration.baseURL.absoluteString == "http://localhost:11434/v1")
        #expect(configuration.apiKey == "")
        #expect(configuration.model == "settings-model")
    }

    @Test
    @MainActor
    func appSettingsProviderFallsBackToEnvironmentWhenSavedAPIKeyIsEmpty() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let (keychainStore, storageDirectory) = Self.temporaryKeychainStore()
        try? keychainStore.delete()
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            try? keychainStore.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        settings.baseURL = "https://settings.example/v1"
        settings.modelName = "settings-model"

        let provider = AppSettingsTransformerProvider(
            settings: settings,
            keychainStore: keychainStore,
            environment: [
                "OPENAI_COMPATIBLE_URL": "https://env.example/v1",
                "OPENAI_COMPATIBLE_API_KEY": "env-key",
                "OPENAI_COMPATIBLE_MODEL": "env-model"
            ]
        )

        let configuration = try provider.openAICompatibleConfiguration()

        #expect(configuration.baseURL.absoluteString == "https://env.example/v1")
        #expect(configuration.apiKey == "env-key")
        #expect(configuration.model == "env-model")
    }

    @Test
    @MainActor
    func appSettingsProviderIgnoresIncompleteEnvironmentWhenSavedAPIKeyIsEmpty() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let (keychainStore, storageDirectory) = Self.temporaryKeychainStore()
        try? keychainStore.delete()
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            try? keychainStore.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        settings.baseURL = "http://localhost:11434/v1"
        settings.modelName = "settings-model"

        let provider = AppSettingsTransformerProvider(
            settings: settings,
            keychainStore: keychainStore,
            environment: [
                "OPENAI_COMPATIBLE_URL": "https://env.example/v1",
                "OPENAI_COMPATIBLE_MODEL": "env-model"
            ]
        )

        let configuration = try provider.openAICompatibleConfiguration()

        #expect(configuration.baseURL.absoluteString == "http://localhost:11434/v1")
        #expect(configuration.apiKey == "")
        #expect(configuration.model == "settings-model")
    }

    @Test
    @MainActor
    func appSettingsProviderUsesSavedSettingsAndLocalAPIKeyBeforeEnvironment() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let (keychainStore, storageDirectory) = Self.temporaryKeychainStore()
        try? keychainStore.delete()
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            try? keychainStore.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        settings.baseURL = "https://settings.example/v1"
        settings.modelName = "settings-model"
        try keychainStore.save("saved-key")

        let provider = AppSettingsTransformerProvider(
            settings: settings,
            keychainStore: keychainStore,
            environment: [
                "OPENAI_COMPATIBLE_URL": "https://env.example/v1",
                "OPENAI_COMPATIBLE_API_KEY": "env-key",
                "OPENAI_COMPATIBLE_MODEL": "env-model"
            ]
        )

        let configuration = try provider.openAICompatibleConfiguration()

        #expect(configuration.baseURL.absoluteString == "https://settings.example/v1")
        #expect(configuration.apiKey == "saved-key")
        #expect(configuration.model == "settings-model")
    }

    @Test
    @MainActor
    func runsAndConnectionTestTreatAWhitespaceSavedKeyTheSame() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        let (keychainStore, storageDirectory) = Self.temporaryKeychainStore()
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
            try? keychainStore.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }
        let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        settings.baseURL = "https://settings.example/v1"
        settings.modelName = "settings-model"
        try keychainStore.save("  \n")
        let environment = [
            "OPENAI_COMPATIBLE_URL": "https://env.example/v1",
            "OPENAI_COMPATIBLE_API_KEY": "env-key",
            "OPENAI_COMPATIBLE_MODEL": "env-model"
        ]

        let run = try AppSettingsTransformerProvider(
            settings: settings, keychainStore: keychainStore, environment: environment
        ).openAICompatibleConfiguration()
        let connectionTest = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
            baseURLString: settings.baseURL, modelName: settings.modelName,
            keychainStore: keychainStore, environment: environment
        )

        #expect(run == connectionTest)
        #expect(run.baseURL.absoluteString == "https://env.example/v1")
    }

    private static func configuration(apiKey: String = "test-key") throws -> OpenAICompatibleConfiguration {
        OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "https://example.com/v1")),
            apiKey: apiKey,
            model: "tiny-model"
        )
    }

    private static func temporaryKeychainStore() -> (KeychainStore, URL) {
        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(testDomainName("SyrupTests"), isDirectory: true)
        let store = KeychainStore(
            service: "org.syrup.SyrupTests",
            storageDirectory: storageDirectory
        )
        return (store, storageDirectory)
    }

    private static func stubbedSession(
        handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        StubURLProtocol.requestHandler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private static func response(statusCode: Int, body: String) -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://example.com/v1/chat/completions")!
        return (
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
            Data(body.utf8)
        )
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let httpBody = request.httpBody {
            data = httpBody
        } else if let httpBodyStream = request.httpBodyStream {
            httpBodyStream.open()
            defer { httpBodyStream.close() }

            var bytes: [UInt8] = []
            let bufferSize = 1_024
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            while httpBodyStream.hasBytesAvailable {
                let count = httpBodyStream.read(buffer, maxLength: bufferSize)
                if count > 0 {
                    bytes.append(contentsOf: UnsafeBufferPointer(start: buffer, count: count))
                } else {
                    break
                }
            }
            data = Data(bytes)
        } else {
            data = Data()
        }

        let json = try JSONSerialization.jsonObject(with: data)
        return try #require(json as? [String: Any])
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        requestHandler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let requestHandler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: TranslationError.invalidResponse)
            return
        }

        do {
            let (response, data) = try requestHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Sends the headers after 0.7 seconds and the body 0.7 seconds later.
final class SlowURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Thread.sleep(forTimeInterval: 0.7)
        let url = request.url ?? URL(string: "https://example.com")!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        Thread.sleep(forTimeInterval: 0.7)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"role":"assistant","content":"late"}}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
