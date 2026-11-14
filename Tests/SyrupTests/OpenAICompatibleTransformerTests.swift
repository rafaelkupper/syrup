import Foundation
import Synchronization
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

    /// The non-streamed request, used only for a server that refuses to stream: headers and body each
    /// arrive within the timeout, but together they take longer. One deadline covers both, so the
    /// request still times out.
    @Test
    func aNonStreamedReplyWhoseHeadersAndBodyTogetherTakeTooLongTimesOut() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowURLProtocol.self]
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(), session: URLSession(configuration: configuration),
            timeoutInterval: 1
        )
        await #expect(throws: TranslationError.timedOut) {
            _ = try await transformer.transformWithUsage("hello", instruction: "Polish it.")
        }
    }

    /// A run that shows no deltas still streams, so a model that keeps generating for longer than the
    /// timeout in total is not cut off: each chunk resets the inactivity deadline.
    @Test
    func aSlowAnswerNobodyWatchesIsStreamedAndNotCutOff() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DripURLProtocol.self]
        DripURLProtocol.streamFlags.withLock { $0 = [] }
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(), session: URLSession(configuration: configuration),
            timeoutInterval: 1
        )
        let output = try await transformer.transform("hello", instruction: "Polish it.")
        #expect(output == "one two three")
        #expect(DripURLProtocol.streamFlags.withLock { $0 } == [true])
    }

    /// A stream that keeps sending reasoning without ever answering is stopped at the first-answer
    /// limit, though every chunk resets the inactivity deadline. The limits are set apart from the
    /// 100 ms chunk rhythm, so a scheduling gap cannot end the stream some other way.
    @Test
    func aStreamThatNeverAnswersStopsAtTheFirstAnswerLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EndlessReasoningURLProtocol.self]
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(), session: URLSession(configuration: configuration),
            timeoutInterval: 2, firstAnswerLimit: .seconds(1)
        )
        let clock = ContinuousClock(), started = clock.now
        await #expect(throws: TranslationError.timedOut) {
            _ = try await transformer.transform("hello", instruction: "Polish it.")
        }
        let elapsed = started.duration(to: clock.now)
        #expect(elapsed >= .seconds(0.9) && elapsed < .seconds(2.5))
    }

    /// Once the answer has started, the first-answer limit no longer applies, so a slow model writing
    /// a long answer is not cut off. The answer takes 3 s against a 2 s limit; the first chunk has two
    /// seconds to arrive, even behind the previous test's fake server, which shares its loading thread.
    @Test
    func aSlowAnswerPastTheFirstAnswerLimitIsNotCutOff() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowAnswerURLProtocol.self]
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(), session: URLSession(configuration: configuration),
            timeoutInterval: 2, firstAnswerLimit: .seconds(2)
        )
        let output = try await transformer.transform("hello", instruction: "Polish it.")
        #expect(output == String(repeating: "word ", count: 12).trimmingCharacters(in: .whitespaces))
    }

    @Test
    func answerContentGivenAsAListOfPartsIsRead() async throws {
        for (streamed, body, mime) in [
            (true, #"data: {"choices":[{"delta":{"content":[{"type":"text","text":"Hel"},{"type":"text","text":"lo"}]}}]}"# + "\n\ndata: [DONE]\n\n", "text/event-stream"),
            (false, #"{"choices":[{"message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]}}]}"#, "application/json"),
        ] {
            let session = Self.stubbedSession { _ in
                let (response, data) = Self.response(statusCode: 200, body: body)
                return (HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
                                        headerFields: ["Content-Type": mime])!, data)
            }
            defer { StubURLProtocol.reset() }
            let transformer = OpenAICompatibleTransformer(configuration: try Self.configuration(), session: session)
            let output = streamed
                ? try await transformer.transform("hello", instruction: "Polish it.")
                : try await transformer.transformWithUsage("hello", instruction: "Polish it.").text
            #expect(output == "Hello")
        }
    }

    /// Some models accept only their default temperature. The request is sent once more without it,
    /// streamed or not, and nothing else is retried. Hand-built shapes: no provider publishes a
    /// temperature rejection body (OpenAI, OpenRouter, Mistral, Groq, DeepSeek, vLLM, LM Studio, and
    /// Ollama documentation checked 2026-11-14; see `ProviderCorpus`).
    @Test(arguments: [true, false], [
        #"{"error":{"message":"Only the default (1) value is supported.","type":"invalid_request_error","param":"temperature","code":"unsupported_value"}}"#,
        #"{"error":{"message":"Unsupported parameter: 'temperature' is not supported with this model.","code":400}}"#,
        #"{"error":{"param":"temperature","code":20015}}"#,
    ])
    func aModelThatRejectsTemperatureIsAskedAgainWithoutIt(streamed: Bool, rejection: String) async throws {
        let sent = Mutex<[(temperature: Double?, stream: Bool)]>([])
        let session = Self.stubbedSession { request in
            let body = try Self.jsonBody(from: request)
            let temperature = body["temperature"] as? Double, stream = body["stream"] as? Bool ?? false
            sent.withLock { $0.append((temperature, stream)) }
            if temperature != nil {
                return Self.response(statusCode: 400, body: rejection)
            }
            let (response, data) = Self.response(statusCode: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"Hello"}}]}"#)
            return (HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "application/json"])!, data)
        }
        defer { StubURLProtocol.reset() }
        // A model name of its own: a rejection is remembered per endpoint and model.
        let configuration = OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "https://example.com/v1")), apiKey: "test-key", model: "temperature-\(UUID())"
        )
        let transformer = OpenAICompatibleTransformer(configuration: configuration, session: session)
        let output = streamed
            ? try await transformer.transform("hello", instruction: "Polish it.")
            : try await transformer.transformWithUsage("hello", instruction: "Polish it.").text
        #expect(output == "Hello")
        let requests = sent.withLock { $0 }
        #expect(requests.map(\.temperature) == [0.3, nil])
        #expect(requests.allSatisfy { $0.stream == streamed })
    }

    /// The rejection is remembered for this endpoint and model, so the next run sends no temperature
    /// at once instead of paying a rejected request every time.
    @Test
    func aTemperatureRejectionIsRememberedForTheModel() async throws {
        let sent = Mutex<[Double?]>([])
        let session = Self.stubbedSession { request in
            let temperature = try Self.jsonBody(from: request)["temperature"] as? Double
            sent.withLock { $0.append(temperature) }
            if temperature != nil {
                return Self.response(statusCode: 400, body: #"{"error":{"param":"temperature","code":"unsupported_value"}}"#)
            }
            return Self.response(statusCode: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"Hello"}}]}"#)
        }
        defer { StubURLProtocol.reset() }
        let configuration = OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "https://example.com/v1")), apiKey: "test-key", model: "default-temperature-only-\(UUID())"
        )
        for _ in 0..<2 {
            let transformer = OpenAICompatibleTransformer(configuration: configuration, session: session)
            #expect(try await transformer.transform("hello", instruction: "Polish it.") == "Hello")
        }
        #expect(sent.withLock { $0 } == [0.3, nil, nil])
    }

    /// Routers phrase the rejection in different shapes; any rejection that mentions the parameter
    /// earns the one retry without it.
    @Test(arguments: [
        #"{"detail":"Unsupported parameter: temperature"}"#,
        #"{"error":"temperature is not supported for this model"}"#,
    ])
    func aTemperatureRejectionInAnotherShapeIsRetried(body: String) async throws {
        let sent = Mutex<[Double?]>([])
        let session = Self.stubbedSession { request in
            let temperature = try Self.jsonBody(from: request)["temperature"] as? Double
            sent.withLock { $0.append(temperature) }
            if temperature != nil { return Self.response(statusCode: 422, body: body) }
            return Self.response(statusCode: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"Hello"}}]}"#)
        }
        defer { StubURLProtocol.reset() }
        let configuration = OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "https://example.com/v1")), apiKey: "test-key", model: "router-\(UUID())"
        )
        let transformer = OpenAICompatibleTransformer(configuration: configuration, session: session)
        #expect(try await transformer.transform("hello", instruction: "Polish it.") == "Hello")
        #expect(sent.withLock { $0 } == [0.3, nil])
    }

    /// Hand-built shapes, not documented ones. A rejection that mentions temperature for another
    /// reason still earns the one retry without it, but is not remembered: the next run sends it again.
    @Test(arguments: [true, false])
    func aMentionOfTemperatureForAnotherReasonIsNotRemembered(streamed: Bool) async throws {
        let sent = Mutex<[Double?]>([])
        let session = Self.stubbedSession { request in
            let temperature = try Self.jsonBody(from: request)["temperature"] as? Double
            sent.withLock { $0.append(temperature) }
            if temperature != nil {
                return Self.response(statusCode: 400, body: #"{"error":{"message":"The text about temperature is longer than the context window.","param":"messages","code":"context_length_exceeded"}}"#)
            }
            return Self.jsonAnswer("Hello")
        }
        defer { StubURLProtocol.reset() }
        let configuration = OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "https://example.com/v1")), apiKey: "test-key", model: "mention-\(UUID())"
        )
        for _ in 0..<2 {
            let transformer = OpenAICompatibleTransformer(configuration: configuration, session: session)
            let output = streamed
                ? try await transformer.transform("hello", instruction: "Polish it.")
                : try await transformer.transformWithUsage("hello", instruction: "Polish it.").text
            #expect(output == "Hello")
        }
        #expect(sent.withLock { $0 } == [0.3, nil, 0.3, nil])
    }

    /// Hand-built shapes. A mention of temperature whose retry fails too changes nothing for later runs.
    @Test
    func aMentionOfTemperatureWhoseRetryFailsIsNotRemembered() async throws {
        let sent = Mutex<[Double?]>([])
        let session = Self.stubbedSession { request in
            let temperature = try Self.jsonBody(from: request)["temperature"] as? Double
            sent.withLock { $0.append(temperature) }
            return Self.response(statusCode: 400, body: #"{"error":{"message":"The text about temperature is longer than the context window.","param":"messages"}}"#)
        }
        defer { StubURLProtocol.reset() }
        let configuration = OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "https://example.com/v1")), apiKey: "test-key", model: "failing-\(UUID())"
        )
        for _ in 0..<2 {
            let transformer = OpenAICompatibleTransformer(configuration: configuration, session: session)
            _ = try? await transformer.transform("hello", instruction: "Polish it.")
        }
        #expect(sent.withLock { $0 } == [0.3, nil, 0.3, nil])
    }

    /// Hand-built shapes. In a stream, a temperature rejection is remembered only once the retry's
    /// answer starts: a retry whose stream fails before any answer leaves the next run sending it.
    @Test(arguments: [false, true])
    func aStreamedRetryRemembersTheRejectionOnlyOnceItsAnswerStarts(answers: Bool) async throws {
        let sent = Mutex<[Double?]>([])
        let session = Self.stubbedSession { request in
            let temperature = try Self.jsonBody(from: request)["temperature"] as? Double
            sent.withLock { $0.append(temperature) }
            if temperature != nil {
                return Self.response(statusCode: 400, body: #"{"error":{"param":"temperature","code":"unsupported_value"}}"#)
            }
            let events = answers
                ? #"data: {"choices":[{"delta":{"content":"Hello"}}]}"# + "\n\ndata: [DONE]\n\n"
                : #"data: {"error":{"message":"The server is overloaded."}}"# + "\n\n"
            return Self.eventStream(events)
        }
        defer { StubURLProtocol.reset() }
        let configuration = OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "https://example.com/v1")), apiKey: "test-key", model: "stream-\(UUID())"
        )
        for _ in 0..<2 {
            let transformer = OpenAICompatibleTransformer(configuration: configuration, session: session)
            _ = try? await transformer.transform("hello", instruction: "Polish it.")
        }
        #expect(sent.withLock { $0 } == (answers ? [0.3, nil, nil] : [0.3, nil, 0.3, nil]))
    }

    @Test
    func anotherRejectedParameterIsNotRetried() async throws {
        let requests = Mutex(0)
        let session = Self.stubbedSession { _ in
            requests.withLock { $0 += 1 }
            return Self.response(statusCode: 400, body: #"{"error":{"param":"model","code":"unsupported_value"}}"#)
        }
        defer { StubURLProtocol.reset() }
        let transformer = OpenAICompatibleTransformer(configuration: try Self.configuration(), session: session)
        await #expect(throws: TranslationError.httpStatus(400)) {
            _ = try await transformer.transform("hello", instruction: "Polish it.")
        }
        #expect(requests.withLock { $0 } == 1)
    }

    /// Cancelling the caller ends the stream early; that must not return the part that arrived.
    @Test
    func aCancelledTransformThrowsInsteadOfReturningPartOfTheAnswer() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DripURLProtocol.self]
        let transformer = OpenAICompatibleTransformer(
            configuration: try Self.configuration(), session: URLSession(configuration: configuration)
        )
        let task = Task { try await transformer.transform("hello", instruction: "Polish it.") }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test
    func aPlainJSONAnswerUnderAnotherContentTypeStillDecodes() async throws {
        let session = Self.stubbedSession { _ in
            let (response, body) = Self.response(statusCode: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"Hello"}}]}"#)
            return (HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "text/plain"])!, body)
        }
        defer { StubURLProtocol.reset() }
        let transformer = OpenAICompatibleTransformer(configuration: try Self.configuration(), session: session)
        #expect(try await transformer.transform("hello", instruction: "Polish it.") == "Hello")
    }

    @Test
    func aProxyPageInsteadOfAnAnswerIsAnInvalidResponse() async throws {
        let session = Self.stubbedSession { _ in
            let (response, body) = Self.response(statusCode: 200, body: "<html><body>Sign in to continue</body></html>")
            return (HTTPURLResponse(url: response.url!, statusCode: 200, httpVersion: nil,
                                    headerFields: ["Content-Type": "text/html"])!, body)
        }
        defer { StubURLProtocol.reset() }
        let transformer = OpenAICompatibleTransformer(configuration: try Self.configuration(), session: session)
        await #expect(throws: TranslationError.invalidResponse) {
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
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
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
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
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
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
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
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
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

    private static func jsonAnswer(_ text: String) -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://example.com/v1/chat/completions")!
        return (
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
            Data(#"{"choices":[{"message":{"role":"assistant","content":"\#(text)"}}]}"#.utf8)
        )
    }

    private static func eventStream(_ events: String) -> (HTTPURLResponse, Data) {
        let url = URL(string: "https://example.com/v1/chat/completions")!
        return (
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!,
            Data(events.utf8)
        )
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

/// Streams three chunks half a second apart, 1.5 seconds in all, and records each request's `stream` flag.
final class DripURLProtocol: URLProtocol, @unchecked Sendable {
    static let streamFlags = Mutex<[Bool]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        } ?? request.httpBody ?? Data()
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        Self.streamFlags.withLock { $0.append(json?["stream"] as? Bool ?? false) }

        let url = request.url ?? URL(string: "https://example.com")!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                              headerFields: ["Content-Type": "text/event-stream"])!,
                            cacheStoragePolicy: .notAllowed)
        for (index, word) in ["one", " two", " three"].enumerated() {
            if index > 0 { Thread.sleep(forTimeInterval: 0.5) }
            client?.urlProtocol(self, didLoad: Data((#"data: {"choices":[{"delta":{"content":"\#(word)"}}]}"# + "\n\n").utf8))
        }
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Streams a reasoning chunk every 100 ms for 2 seconds and never answers. Custom protocols share a
/// loading thread, so it stops soon after the test's 1 s limit rather than delaying the next test.
final class EndlessReasoningURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://example.com")!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                              headerFields: ["Content-Type": "text/event-stream"])!,
                            cacheStoragePolicy: .notAllowed)
        let chunk = Data((#"data: {"choices":[{"delta":{"reasoning_content":"still thinking"}}]}"# + "\n\n").utf8)
        for _ in 0..<20 {
            client?.urlProtocol(self, didLoad: chunk)
            Thread.sleep(forTimeInterval: 0.1)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Answers in twelve chunks 250 ms apart, 3 seconds in all.
final class SlowAnswerURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://example.com")!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                              headerFields: ["Content-Type": "text/event-stream"])!,
                            cacheStoragePolicy: .notAllowed)
        let chunk = Data((#"data: {"choices":[{"delta":{"content":"word "}}]}"# + "\n\n").utf8)
        for _ in 0..<12 {
            client?.urlProtocol(self, didLoad: chunk)
            Thread.sleep(forTimeInterval: 0.25)
        }
        client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
