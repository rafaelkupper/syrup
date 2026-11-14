import Foundation

struct OpenAICompatibleConfiguration: Equatable, Sendable {
    let baseURL: URL
    let apiKey: String
    let model: String

    init(baseURL: URL, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    static func userSettings(
        baseURLString: String,
        apiKey: String,
        modelName: String
    ) throws -> OpenAICompatibleConfiguration {
        let trimmedURL = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: trimmedURL),
              let scheme = baseURL.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              baseURL.host() != nil
        else {
            throw TranslationError.invalidBaseURL(baseURLString)
        }

        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedModelName.isEmpty == false else {
            throw TranslationError.missingConfiguration("modelName")
        }

        return OpenAICompatibleConfiguration(
            baseURL: baseURL,
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            model: trimmedModelName
        )
    }

    static func environment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> OpenAICompatibleConfiguration {
        guard let rawURL = environment["OPENAI_COMPATIBLE_URL"],
              rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw TranslationError.missingConfiguration("OPENAI_COMPATIBLE_URL")
        }

        guard let apiKey = environment["OPENAI_COMPATIBLE_API_KEY"],
              apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw TranslationError.missingConfiguration("OPENAI_COMPATIBLE_API_KEY")
        }

        guard let model = environment["OPENAI_COMPATIBLE_MODEL"],
              model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw TranslationError.missingConfiguration("OPENAI_COMPATIBLE_MODEL")
        }

        return try userSettings(
            baseURLString: rawURL,
            apiKey: apiKey,
            modelName: model
        )
    }
}

protocol OpenAICompatibleConfigurationProviding: Sendable {
    func configuration() async throws -> OpenAICompatibleConfiguration
}

struct StaticOpenAICompatibleConfigurationProvider: OpenAICompatibleConfigurationProviding {
    let endpoint: OpenAICompatibleConfiguration

    func configuration() async throws -> OpenAICompatibleConfiguration {
        endpoint
    }
}

struct EnvironmentOpenAICompatibleConfigurationProvider: OpenAICompatibleConfigurationProviding {
    func configuration() async throws -> OpenAICompatibleConfiguration {
        try OpenAICompatibleConfiguration.environment()
    }
}

struct OpenAICompatibleTokenUsage: Decodable, Equatable, Sendable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?

    private enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

struct OpenAICompatibleTranslationResult: Equatable, Sendable {
    let text: String
    let usage: OpenAICompatibleTokenUsage?
}

struct OpenAICompatibleTransformer: StreamingTextTransformer {
    private let configurationProvider: any OpenAICompatibleConfigurationProviding
    private let session: URLSession
    private let timeoutInterval: TimeInterval
    private let inactivitySleeper: StreamingInactivitySleeper

    init(
        configuration: OpenAICompatibleConfiguration? = nil,
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = 30,
        inactivitySleeper: @escaping StreamingInactivitySleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.configurationProvider = if let configuration {
            StaticOpenAICompatibleConfigurationProvider(endpoint: configuration)
        } else {
            EnvironmentOpenAICompatibleConfigurationProvider()
        }
        self.session = session
        self.timeoutInterval = timeoutInterval
        self.inactivitySleeper = inactivitySleeper
    }

    init(
        configurationProvider: any OpenAICompatibleConfigurationProviding,
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = 30,
        inactivitySleeper: @escaping StreamingInactivitySleeper = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.configurationProvider = configurationProvider
        self.session = session
        self.timeoutInterval = timeoutInterval
        self.inactivitySleeper = inactivitySleeper
    }

    func transform(_ text: String, instruction: String) async throws -> String {
        try await transformWithUsage(text, instruction: instruction).text
    }

    func transformStream(
        _ text: String,
        instruction: String
    ) -> AsyncThrowingStream<String, any Error> {
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let task = Task {
            var endpointHost = "endpoint"
            do {
                let configuration = try await configurationProvider.configuration()
                endpointHost = configuration.baseURL.host() ?? endpointHost
                let request = try makeRequest(
                    text: text,
                    instruction: instruction,
                    endpoint: configuration,
                    streaming: true
                )
                let (bytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TranslationError.invalidResponse
                }
                if [400, 422, 501].contains(httpResponse.statusCode) {
                    let data = try await readResponseBody(bytes)
                    if Self.isStreamingUnsupported(data) {
                        throw StreamingTransformError.requiresAtomicFallback
                    }
                }
                try validate(httpResponse)

                if httpResponse.mimeType?.lowercased() == "application/json" {
                    let data = try await readResponseBody(bytes)
                    let result = try Self.decodeCompletion(
                        data,
                        keepsWrapperQuotes: ModelOutputNormalizer.requestsQuotes(input: text, instruction: instruction)
                    )
                    try Task.checkCancellation()
                    continuation.yield(result.text)
                    continuation.finish()
                    return
                }

                let timeout = Duration.milliseconds(Int64(timeoutInterval * 1_000))
                try await Self.consumeSSE(
                    bytes: bytes,
                    endpointHost: endpointHost,
                    inactivityTimeout: timeout,
                    inactivitySleeper: inactivitySleeper
                ) { delta in
                    continuation.yield(delta)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: Self.streamingError(error, host: endpointHost))
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    func transformWithUsage(
        _ text: String,
        instruction: String
    ) async throws -> OpenAICompatibleTranslationResult {
        let configuration = try await configurationProvider.configuration()
        let request = try makeRequest(
            text: text,
            instruction: instruction,
            endpoint: configuration,
            streaming: false
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationError.invalidResponse
            }

            try validate(httpResponse)

            return try Self.decodeCompletion(
                data,
                keepsWrapperQuotes: ModelOutputNormalizer.requestsQuotes(input: text, instruction: instruction)
            )
        } catch let error as TranslationError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw TranslationError.cannotConnect(configuration.baseURL.host() ?? "endpoint")
            case .timedOut:
                throw TranslationError.timedOut
            default:
                throw TranslationError.cannotConnect(configuration.baseURL.host() ?? "endpoint")
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranslationError.invalidResponse
        }
    }

    static func chatCompletionsURL(baseURL: URL) throws -> URL {
        let trimmedBaseURL = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let normalizedBaseURL = URL(string: trimmedBaseURL) else {
            throw TranslationError.invalidBaseURL(baseURL.absoluteString)
        }

        return normalizedBaseURL.appending(path: "chat/completions")
    }

    static func validateFinishReason(_ reason: String?) throws {
        switch reason {
        case "length": throw TranslationError.outputLimitReached
        case "content_filter": throw TranslationError.responseFiltered
        default: break
        }
    }

    private static func decodeCompletion(_ data: Data, keepsWrapperQuotes: Bool) throws -> OpenAICompatibleTranslationResult {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let choice = response.choices.first else { throw TranslationError.emptyResponse }
        try validateFinishReason(choice.finishReason)
        guard let content = choice.message.content else { throw TranslationError.emptyResponse }
        let text = ModelOutputNormalizer.normalize(content, keepsWrapperQuotes: keepsWrapperQuotes)
        guard text.isEmpty == false else { throw TranslationError.emptyResponse }
        return OpenAICompatibleTranslationResult(text: text, usage: response.usage)
    }

    private func readResponseBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        try await withOperationTimeout(
            .milliseconds(Int64(timeoutInterval * 1_000)), error: TranslationError.timedOut
        ) {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
            }
            return data
        }
    }

    private static func isStreamingUnsupported(_ data: Data) -> Bool {
        guard let rejection = try? JSONDecoder().decode(StreamingRejection.self, from: data),
              rejection.error.param == "stream" else { return false }
        return ["unsupported_parameter", "unsupported_value", "not_supported"]
            .contains(rejection.error.code ?? "")
    }

    private func makeRequest(
        text: String,
        instruction: String,
        endpoint: OpenAICompatibleConfiguration,
        streaming: Bool
    ) throws -> URLRequest {
        let url = try Self.chatCompletionsURL(baseURL: endpoint.baseURL)
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if endpoint.apiKey.isEmpty == false {
            request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let messages = [
            ChatMessage(role: "system", content: instruction),
            ChatMessage(role: "user", content: text),
        ]
        if streaming {
            request.httpBody = try JSONEncoder().encode(StreamingChatCompletionRequest(
                model: endpoint.model,
                temperature: 0.3,
                messages: messages,
                stream: true
            ))
        } else {
            request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
                model: endpoint.model,
                temperature: 0.3,
                messages: messages
            ))
        }
        return request
    }

    static func consumeSSE<Bytes: AsyncSequence & Sendable>(
        bytes: Bytes,
        endpointHost: String,
        inactivityTimeout: Duration,
        inactivitySleeper: @escaping StreamingInactivitySleeper,
        lineObserver: @escaping @Sendable () -> Void = {},
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws where Bytes.Element == UInt8 {
        let (eventStream, eventContinuation) = AsyncThrowingStream<OpenAISSEEvent, any Error>
            .makeStream()
        let watchdog = StreamingInactivityWatchdog(
            timeout: inactivityTimeout,
            sleeper: inactivitySleeper,
            onTimeout: {
                eventContinuation.finish(throwing: TranslationError.timedOut)
            }
        )
        await watchdog.start()

        let parserTask = Task {
            do {
                var parser = OpenAISSEParser()
                var lineBytes: [UInt8] = []
                for try await byte in bytes {
                    try Task.checkCancellation()
                    lineBytes.append(byte)
                    guard byte == 0x0A || byte == 0x0D else { continue }

                    let chunk = String(decoding: lineBytes, as: UTF8.self)
                    lineBytes.removeAll(keepingCapacity: true)
                    let receivedDone = await Self.forwardParserEvents(
                        try parser.append(chunk),
                        to: eventContinuation,
                        watchdog: watchdog
                    )
                    lineObserver()
                    if receivedDone {
                        eventContinuation.finish()
                        return
                    }
                }

                if lineBytes.isEmpty == false {
                    let receivedDone = await Self.forwardParserEvents(
                        try parser.append(String(decoding: lineBytes, as: UTF8.self)),
                        to: eventContinuation,
                        watchdog: watchdog
                    )
                    lineObserver()
                    if receivedDone {
                        eventContinuation.finish()
                        return
                    }
                }

                if await Self.forwardParserEvents(
                    try parser.finish(),
                    to: eventContinuation,
                    watchdog: watchdog
                ) {
                    eventContinuation.finish()
                    return
                }
                guard parser.didReceiveDone else {
                    throw TranslationError.cannotConnect(endpointHost)
                }
                eventContinuation.finish()
            } catch {
                eventContinuation.finish(throwing: error)
            }
        }

        do {
            for try await event in eventStream {
                switch event {
                case .delta(let delta):
                    onDelta(delta)
                case .done:
                    await watchdog.cancel()
                    await parserTask.value
                    return
                }
            }

            try Task.checkCancellation()
            parserTask.cancel()
            await watchdog.cancel()
            await parserTask.value
            throw TranslationError.cannotConnect(endpointHost)
        } catch {
            parserTask.cancel()
            await watchdog.cancel()
            await parserTask.value
            throw error
        }
    }

    private static func forwardParserEvents(
        _ events: [OpenAISSEEvent],
        to continuation: AsyncThrowingStream<OpenAISSEEvent, any Error>.Continuation,
        watchdog: StreamingInactivityWatchdog
    ) async -> Bool {
        for event in events {
            switch event {
            case .delta(let delta):
                await watchdog.noteDelta()
                continuation.yield(.delta(delta))
            case .done:
                continuation.yield(.done)
                return true
            }
        }
        return false
    }

    private static func streamingError(_ error: any Error, host: String) -> any Error {
        if error is CancellationError {
            return CancellationError()
        }
        if let translationError = error as? TranslationError {
            return translationError
        }
        if let fallback = error as? StreamingTransformError { return fallback }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled, Task.isCancelled {
                return CancellationError()
            }
            if urlError.code == .timedOut {
                return TranslationError.timedOut
            }
            return TranslationError.cannotConnect(host)
        }
        return TranslationError.invalidResponse
    }

    private func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw TranslationError.apiKeyRejected
        case 429:
            throw TranslationError.rateLimited
        default:
            throw TranslationError.httpStatus(response.statusCode)
        }
    }
}

struct OpenAICompatibleEndpointTester: Sendable {
    private let session: URLSession
    private let timeoutInterval: TimeInterval

    init(session: URLSession = .shared, timeoutInterval: TimeInterval = 10) {
        self.session = session
        self.timeoutInterval = timeoutInterval
    }

    func testConnection(configuration: OpenAICompatibleConfiguration) async throws {
        let transformer = OpenAICompatibleTransformer(
            configuration: configuration,
            session: session,
            timeoutInterval: timeoutInterval
        )
        _ = try await transformer.transformWithUsage(
            "hi",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
        )
    }
}

private struct ChatCompletionRequest: Encodable, Equatable {
    let model: String
    let temperature: Double
    let messages: [ChatMessage]
}

private struct StreamingChatCompletionRequest: Encodable, Equatable {
    let model: String
    let temperature: Double
    let messages: [ChatMessage]
    let stream: Bool
}

private struct ChatMessage: Codable, Equatable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [ChatChoice]
    let usage: OpenAICompatibleTokenUsage?
}

private struct ChatChoice: Decodable {
    struct Message: Decodable {
        let content: String?
    }
    let message: Message
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

private struct StreamingRejection: Decodable {
    struct Detail: Decodable {
        let param: String?
        let code: String?
    }
    let error: Detail
}
