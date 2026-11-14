import Foundation
import Synchronization

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

    static func environment(_ environment: [String: String]) throws -> OpenAICompatibleConfiguration {
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
    private let configuration: OpenAICompatibleConfiguration
    private let session: URLSession
    private let timeoutInterval: TimeInterval
    private let inactivitySleeper: StreamingInactivitySleeper
    /// How long a streamed request may take to start its answer; see `transformStream`.
    private let firstAnswerLimit: Duration

    /// `firstAnswerLimit` defaults to ten times the timeout: five minutes by default.
    init(
        configuration: OpenAICompatibleConfiguration,
        session: URLSession = .shared,
        timeoutInterval: TimeInterval = 30,
        inactivitySleeper: @escaping StreamingInactivitySleeper = { duration in
            try await Task.sleep(for: duration)
        },
        firstAnswerLimit: Duration? = nil
    ) {
        self.configuration = configuration
        self.session = session
        self.timeoutInterval = timeoutInterval
        self.inactivitySleeper = inactivitySleeper
        self.firstAnswerLimit = firstAnswerLimit ?? .milliseconds(Int64(timeoutInterval * 10_000))
    }

    /// A reply that ends without one event; see `consumeSSE`.
    struct NotAnEventStream: Error, Equatable {
        let body: Data
    }

    /// Streams the request even when nobody watches the deltas, so every run has the same transport
    /// and the same deadline: the inactivity timeout, which a model still generating keeps resetting.
    /// A non-streamed request has to finish within one fixed deadline, which cuts off a slow model's
    /// long answer. It remains the fallback for a server that refuses to stream.
    func transform(_ text: String, instruction: String) async throws -> String {
        var output = ""
        do {
            for try await delta in transformStream(text, instruction: instruction) {
                output += delta
            }
        } catch StreamingTransformError.requiresAtomicFallback {
            return try await transformAfterStreamingFallback(text, instruction: instruction)
        }
        // A cancelled caller's stream just ends, so what arrived is not the whole answer.
        try Task.checkCancellation()
        let answer = ModelOutputNormalizer.normalize(
            output,
            keepsWrapperQuotes: ModelOutputNormalizer.requestsQuotes(input: text, instruction: instruction)
        )
        guard answer.isEmpty == false else { throw TranslationError.emptyResponse }
        return answer
    }

    func transformAfterStreamingFallback(_ text: String, instruction: String) async throws -> String {
        try await transformWithUsage(text, instruction: instruction).text
    }

    func transformStream(
        _ text: String,
        instruction: String
    ) -> AsyncThrowingStream<String, any Error> {
        let (stream, continuation) = AsyncThrowingStream<String, any Error>.makeStream()
        let endpointHost = configuration.baseURL.host() ?? "endpoint"
        let task = Task { [self] in
            // The inactivity deadline ends a stalled stream. This limit caps one that keeps sending
            // without ever answering, such as a server repeating chunks that carry only reasoning or
            // nothing. It ends when the answer starts: from then the inactivity deadline and the 8 MB
            // cap bound the stream, so a slow model writing a long answer is not cut off.
            let firstAnswerDeadline = Task {
                try? await Task.sleep(for: firstAnswerLimit)
                guard Task.isCancelled == false else { return }
                continuation.finish(throwing: TranslationError.timedOut)
            }
            do {
                try await self.stream(
                    text, instruction: instruction, endpointHost: endpointHost,
                    into: continuation, answerStarted: { firstAnswerDeadline.cancel() }
                )
                firstAnswerDeadline.cancel()
                continuation.finish()
            } catch {
                firstAnswerDeadline.cancel()
                continuation.finish(throwing: Self.streamingError(error, host: endpointHost))
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return stream
    }

    private func stream(
        _ text: String, instruction: String, endpointHost: String,
        into continuation: AsyncThrowingStream<String, any Error>.Continuation,
        answerStarted: @escaping @Sendable () -> Void
    ) async throws {
        let yield: @Sendable (String) -> Void = { text in
            answerStarted()
            continuation.yield(text)
        }
        var sendsTemperature = sendsTemperatureFirst
        while true {
            let request = try makeRequest(
                text: text,
                instruction: instruction,
                endpoint: configuration,
                streaming: true,
                sendsTemperature: sendsTemperature
            )
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw TranslationError.invalidResponse
            }
            if Self.rejectionStatuses.contains(httpResponse.statusCode) {
                let data = try await readResponseBodyWithTimeout(bytes)
                if Self.rejectsStreaming(data) { throw StreamingTransformError.requiresAtomicFallback }
                if sendsTemperature, Self.rejectsTemperature(data) {
                    sendsTemperature = false
                    continue
                }
            }
            try Self.validate(httpResponse)
            // Remembered only once the request without it went through, so an unrelated error that
            // happens to mention it changes nothing for later runs.
            if sendsTemperature == false { rememberTemperatureRejection() }

            // A JSON answer passes on its content as a streamed one does, so the consumer normalizes
            // either once, the same way.
            if httpResponse.mimeType?.lowercased() == "application/json" {
                let data = try await readResponseBodyWithTimeout(bytes)
                let content = try Self.decodeCompletionContent(data).content
                try Task.checkCancellation()
                yield(content)
                return
            }

            do {
                try await Self.consumeSSE(
                    bytes: bytes,
                    endpointHost: endpointHost,
                    inactivityTimeout: timeout,
                    inactivitySleeper: inactivitySleeper
                ) { delta in
                    yield(delta)
                }
            } catch let reply as NotAnEventStream {
                // A 200 without a single event: a JSON answer sent as `text/plain`, or not an answer,
                // such as a proxy's HTML page, which fails to decode as an invalid response.
                let content = try Self.decodeCompletionContent(reply.body).content
                try Task.checkCancellation()
                yield(content)
            }
            return
        }
    }

    func transformWithUsage(
        _ text: String,
        instruction: String
    ) async throws -> OpenAICompatibleTranslationResult {
        let withTemperature = try makeRequest(text: text, instruction: instruction, endpoint: configuration, streaming: false)
        let withoutTemperature = try makeRequest(
            text: text, instruction: instruction, endpoint: configuration, streaming: false, sendsTemperature: false
        )

        let keepsWrapperQuotes = ModelOutputNormalizer.requestsQuotes(input: text, instruction: instruction)
        do {
            // One deadline covers the reply's headers and its body together. The body goes through the
            // bounded reader, not `data(for:)`, so a runaway body stops at the limit instead of being
            // held in memory whole. Runs reach this only through the streaming fallback (see `transform`).
            // A model that rejects `temperature` is asked once more without it.
            let sendsTemperatureFirst = sendsTemperatureFirst
            return try await withOperationTimeout(timeout, error: TranslationError.timedOut) { [session, self] in
                var sendsTemperature = sendsTemperatureFirst
                while true {
                    let (bytes, response) = try await session.bytes(for: sendsTemperature ? withTemperature : withoutTemperature)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw TranslationError.invalidResponse
                    }
                    let data = try await Self.readResponseBody(bytes)
                    if sendsTemperature, Self.rejectionStatuses.contains(httpResponse.statusCode),
                       Self.rejectsTemperature(data) {
                        sendsTemperature = false
                        continue
                    }
                    try Self.validate(httpResponse)
                    if sendsTemperature == false { rememberTemperatureRejection() }
                    return try Self.decodeCompletion(data, keepsWrapperQuotes: keepsWrapperQuotes)
                }
            }
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
        case "error": throw TranslationError.providerReportedError
        default: break
        }
    }

    private static func decodeCompletion(_ data: Data, keepsWrapperQuotes: Bool) throws -> OpenAICompatibleTranslationResult {
        let (content, usage) = try decodeCompletionContent(data)
        let text = ModelOutputNormalizer.normalize(content, keepsWrapperQuotes: keepsWrapperQuotes)
        guard text.isEmpty == false else { throw TranslationError.emptyResponse }
        return OpenAICompatibleTranslationResult(text: text, usage: usage)
    }

    /// The answer as the model wrote it, before normalizing.
    private static func decodeCompletionContent(_ data: Data) throws -> (content: String, usage: OpenAICompatibleTokenUsage?) {
        let response = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let choice = response.choices.first else { throw TranslationError.emptyResponse }
        try validateFinishReason(choice.finishReason)
        guard let content = choice.message.content else { throw TranslationError.emptyResponse }
        return (content, response.usage)
    }

    /// The most a reply may send, streamed or not. A chat answer is kilobytes; a streamed one carries
    /// a few hundred bytes of framing per delta, so this still leaves room for long answers while
    /// stopping a server or a looping model that never ends.
    static let responseBodyLimit = 8 * 1_024 * 1_024

    private var timeout: Duration { .milliseconds(Int64(timeoutInterval * 1_000)) }

    private static func readResponseBody(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            guard data.count <= responseBodyLimit else { throw TranslationError.responseTooLarge }
        }
        return data
    }

    /// A body read after the streaming request's headers, which have their own timeout.
    private func readResponseBodyWithTimeout(_ bytes: URLSession.AsyncBytes) async throws -> Data {
        try await withOperationTimeout(timeout, error: TranslationError.timedOut) {
            try await Self.readResponseBody(bytes)
        }
    }

    /// Replies whose body may say a request parameter is unsupported; both paths read them the same way.
    private static let rejectionStatuses: Set<Int> = [400, 422, 501]

    /// The reply names `stream` as unsupported, with one of the codes servers use for that.
    private static func rejectsStreaming(_ data: Data) -> Bool {
        guard let rejection = try? JSONDecoder().decode(ParameterRejection.self, from: data) else { return false }
        return rejection.error.param == "stream"
            && ["unsupported_parameter", "unsupported_value", "not_supported"].contains(rejection.error.code ?? "")
    }

    /// The reply rejects `temperature`, as a model that accepts only its default does. Servers phrase
    /// that in many shapes (`error.param`, `error.message`, a bare `error` string, `detail`), so any
    /// rejection body that names the parameter counts. Asked only of a request that sent one, and
    /// retried once without it, so a wrong guess costs one request.
    private static func rejectsTemperature(_ data: Data) -> Bool {
        String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("temperature")
    }

    /// Endpoints and models that rejected `temperature` during this session: their requests leave it
    /// out from the start instead of paying a rejected request on every run.
    private static let modelsWithoutTemperature = Mutex<Set<String>>([])

    private var temperatureKey: String { "\(configuration.baseURL.absoluteString)|\(configuration.model)" }

    private var sendsTemperatureFirst: Bool {
        Self.modelsWithoutTemperature.withLock { $0.contains(temperatureKey) } == false
    }

    private func rememberTemperatureRejection() {
        let key = temperatureKey
        _ = Self.modelsWithoutTemperature.withLock { $0.insert(key) }
    }

    private func makeRequest(
        text: String,
        instruction: String,
        endpoint: OpenAICompatibleConfiguration,
        streaming: Bool,
        sendsTemperature: Bool = true
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
                temperature: sendsTemperature ? 0.3 : nil,
                messages: messages,
                stream: true
            ))
        } else {
            request.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
                model: endpoint.model,
                temperature: sendsTemperature ? 0.3 : nil,
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
        byteLimit: Int = responseBodyLimit,
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
                var byteCount = 0
                // Until the first event, what arrived apart from comments: a 200 that never sends an
                // event may be a JSON answer under another content type.
                var bodyBeforeEvents: [UInt8] = []
                for try await byte in bytes {
                    try Task.checkCancellation()
                    // Text keeps the inactivity timer from firing, so a model stuck in a loop would
                    // otherwise stream forever; a line that never ends would grow without bound.
                    byteCount += 1
                    guard byteCount <= byteLimit else { throw TranslationError.responseTooLarge }
                    lineBytes.append(byte)
                    guard byte == 0x0A || byte == 0x0D else { continue }

                    if parser.dataChunks == 0, lineBytes.first != UInt8(ascii: ":") {
                        bodyBeforeEvents += lineBytes
                    }
                    let chunk = String(decoding: lineBytes, as: UTF8.self)
                    lineBytes.removeAll(keepingCapacity: true)
                    let progressBefore = parser.progressChunks
                    let events = try parser.append(chunk)
                    // A chunk with text is progress, answer or reasoning; an empty one or a comment is not.
                    if parser.progressChunks > progressBefore { await watchdog.noteProgress() }
                    let receivedDone = Self.forwardParserEvents(
                        events,
                        to: eventContinuation
                    )
                    lineObserver()
                    if receivedDone {
                        eventContinuation.finish()
                        return
                    }
                }

                if lineBytes.isEmpty == false {
                    if parser.dataChunks == 0, lineBytes.first != UInt8(ascii: ":") {
                        bodyBeforeEvents += lineBytes
                    }
                    let receivedDone = Self.forwardParserEvents(
                        try parser.append(String(decoding: lineBytes, as: UTF8.self)),
                        to: eventContinuation
                    )
                    lineObserver()
                    if receivedDone {
                        eventContinuation.finish()
                        return
                    }
                }

                if Self.forwardParserEvents(
                    try parser.finish(),
                    to: eventContinuation
                ) {
                    eventContinuation.finish()
                    return
                }
                // Not one event. With nothing but whitespace and comments it is a dropped connection;
                // otherwise the caller decides whether it is an answer.
                if parser.dataChunks == 0 {
                    let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
                    guard bodyBeforeEvents.contains(where: { whitespace.contains($0) == false }) else {
                        throw TranslationError.cannotConnect(endpointHost)
                    }
                    throw NotAnEventStream(body: Data(bodyBeforeEvents))
                }
                // `finish_reason: stop` then EOF is a complete answer from servers that never send `[DONE]`.
                // EOF with neither marker is a dropped connection.
                guard parser.didReceiveStop else {
                    throw TranslationError.cannotConnect(endpointHost)
                }
                eventContinuation.yield(.done)
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
        to continuation: AsyncThrowingStream<OpenAISSEEvent, any Error>.Continuation
    ) -> Bool {
        for event in events {
            switch event {
            case .delta(let delta):
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

    private static func validate(_ response: HTTPURLResponse) throws {
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
        // The same request runs send, streamed, so a proxy that breaks streaming fails here too.
        _ = try await transformer.transform(
            "hi",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
        )
    }
}

private struct ChatCompletionRequest: Encodable, Equatable {
    let model: String
    /// Nil leaves it out, for a model that accepts only its default.
    let temperature: Double?
    let messages: [ChatMessage]
}

private struct StreamingChatCompletionRequest: Encodable, Equatable {
    let model: String
    /// Nil leaves it out, for a model that accepts only its default.
    let temperature: Double?
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
        /// A string, or the text of a list of parts.
        let content: String?

        enum CodingKeys: String, CodingKey { case content }

        init(from decoder: any Decoder) throws {
            content = try decoder.container(keyedBy: CodingKeys.self)
                .decodeIfPresent(JSONFieldValue.self, forKey: .content)?.text
        }
    }
    let message: Message
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

private struct ParameterRejection: Decodable {
    struct Detail: Decodable {
        let param: String?
        /// A string, or a number written as one; some routers send a numeric code.
        let code: String?

        enum CodingKeys: String, CodingKey { case param, code }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            param = try? container.decodeIfPresent(String.self, forKey: .param)
            code = (try? container.decodeIfPresent(String.self, forKey: .code))
                ?? (try? container.decodeIfPresent(Int.self, forKey: .code)).flatMap { $0.map(String.init) }
        }
    }
    let error: Detail
}
