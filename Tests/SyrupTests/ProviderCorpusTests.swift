import Foundation
import Synchronization
import Testing
@testable import Syrup

struct ProviderStreamCase: Sendable, CustomTestStringConvertible {
    enum End: Sendable { case open, stop, done, stopDone, providerError }
    let provider: String
    let label: String
    let source: String
    let nearby: String
    let note: String
    let lines: [String]
    let text: String
    let progress: Int
    let end: End
    var testDescription: String { "\(provider): \(label)" }
}

struct ProviderErrorCase: Sendable, CustomTestStringConvertible {
    enum Expected: Sendable { case httpStatus, rateLimited, providerError }
    let provider: String
    let label: String
    let source: String
    let nearby: String
    let note: String
    /// The status shown with the example, if the page shows one.
    let status: Int?
    let body: String
    let expected: Expected?
    var testDescription: String { "\(provider): \(label)" }
}

/// What providers document that they send (`ProviderCorpus`), run through the parser and the
/// rejection checks. Expectations come from what each page says the example carries.
struct ProviderCorpusTests {
    @Test(arguments: ProviderCorpus.streams)
    func documentedStreamsParseAsDocumented(_ example: ProviderStreamCase) throws {
        var parser = OpenAISSEParser()
        var text = ""
        var thrown: (any Error)?
        do {
            var events = try parser.append(example.lines.joined(separator: "\n") + "\n")
            events += try parser.finish()
            for event in events { if case .delta(let delta) = event { text += delta } }
        } catch {
            thrown = error
        }
        if example.end == .providerError {
            #expect(thrown as? TranslationError == .providerReportedError, "\(example.source)")
            return
        }
        #expect(thrown == nil, "\(example.source)")
        #expect(text == example.text, "\(example.source)")
        #expect(parser.progressChunks == example.progress, "\(example.source)")
        #expect(parser.didReceiveDone == (example.end == .done || example.end == .stopDone), "\(example.source)")
        #expect(parser.didReceiveStop == (example.end == .stop || example.end == .stopDone), "\(example.source)")
    }

    /// No documented error, from any provider, is read as a rejection of `temperature` or of
    /// streaming: those are the only rejections the transformer retries or remembers. No documented
    /// error mentions either; most name no parameter, so this also guards that a rejection naming no
    /// parameter counts only when it mentions temperature.
    @Test(arguments: ProviderCorpus.errors)
    func noDocumentedErrorReadsAsATemperatureOrStreamingRejection(_ example: ProviderErrorCase) {
        let data = Data(example.body.utf8)
        #expect(OpenAICompatibleTransformer.rejectsTemperature(data) == false, "\(example.source)")
        #expect(OpenAICompatibleTransformer.namesTemperatureAsRejected(data) == false, "\(example.source)")
        #expect(OpenAICompatibleTransformer.rejectsStreaming(data) == false, "\(example.source)")
    }

    @Test func theCorpusCoversTheProvidersItNames() {
        let providers = Set(ProviderCorpus.streams.map(\.provider) + ProviderCorpus.errors.map(\.provider))
        #expect(providers == ["OpenAI", "OpenRouter", "Mistral", "Groq", "DeepSeek", "vLLM", "Ollama"])
        #expect(ProviderCorpus.streams.allSatisfy { $0.source.hasPrefix("https://") && $0.nearby.isEmpty == false })
        #expect(ProviderCorpus.errors.allSatisfy { $0.source.hasPrefix("https://") && $0.nearby.isEmpty == false })
    }
}

extension OpenAICompatibleTransformerTests {
    /// Each documented error shown with a status, as the reply to a request, streamed and not: it maps
    /// to its error, after exactly one request, so nothing documented is retried.
    @Test(arguments: ProviderCorpus.errors.filter { $0.status != nil && $0.expected != nil }, [true, false])
    func documentedErrorsMapToTheirErrorsWithoutARetry(_ example: ProviderErrorCase, streamed: Bool) async throws {
        let status = try #require(example.status)
        let requests = Mutex(0)
        StubURLProtocol.requestHandler = { request in
            requests.withLock { $0 += 1 }
            let url = request.url ?? URL(string: "https://example.com/v1/chat/completions")!
            return (
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                Data(example.body.utf8)
            )
        }
        defer { StubURLProtocol.reset() }
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        let configuration = OpenAICompatibleConfiguration(
            baseURL: try #require(URL(string: "https://example.com/v1")), apiKey: "test-key", model: "corpus-\(UUID())"
        )
        let transformer = OpenAICompatibleTransformer(configuration: configuration, session: URLSession(configuration: sessionConfiguration))
        let expected: TranslationError = switch try #require(example.expected) {
        case .httpStatus: .httpStatus(status)
        case .rateLimited: .rateLimited
        case .providerError: .providerReportedError
        }
        await #expect(throws: expected, "\(example.source)") {
            if streamed {
                _ = try await transformer.transform("hello", instruction: "Polish it.")
            } else {
                _ = try await transformer.transformWithUsage("hello", instruction: "Polish it.")
            }
        }
        #expect(requests.withLock { $0 } == 1, "\(example.source)")
    }
}
