import AVFoundation
import Foundation
import KeyboardShortcuts
import Synchronization
import Testing
@testable import Syrup

/// Server-sent event parsing for streamed OpenAI-compatible replies.
@MainActor
struct OpenAISSEParsingTests {
    @Test func aStopFinishReasonMarksTheAnswerCompleteWithoutDone() throws {
        var parser = OpenAISSEParser()
        let events = try parser.append(
            #"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"# + "\n\n"
            + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\n"
        )
        #expect(events == [.delta("Hi")])
        #expect(parser.didReceiveStop)
        #expect(parser.didReceiveDone == false)

        var interrupted = OpenAISSEParser()
        _ = try interrupted.append(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n\n")
        #expect(interrupted.didReceiveStop == false)
    }

    @Test func sseAcceptsCRLFLikeLF() throws {
        let payload = #"data: {"choices":[{"delta":{"content":"hello"}}]}"#
        var control = OpenAISSEParser()
        #expect(try control.append(payload + "\n\ndata: [DONE]\n\n") == [.delta("hello"), .done])
        var parser = OpenAISSEParser()
        let events = try parser.append(payload + "\r\n\r\ndata: [DONE]\r\n\r\n")
        #expect(events == [.delta("hello"), .done])
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func sseAcceptsLineEndingsSplitAcrossChunks(ending: String) throws {
        let payload = #"data: {"choices":[{"delta":{"content":"Olá"}}]}"# + ending + ending + "data: [DONE]" + ending
        var parser = OpenAISSEParser()
        var events: [OpenAISSEEvent] = []
        for scalar in payload.unicodeScalars { events += try parser.append(String(scalar)) }
        events += try parser.finish()
        #expect(events == [.delta("Olá"), .done])
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func streamCompletesWithSupportedLineEndings(ending: String) async throws {
        let bytes = AsyncThrowingStream<UInt8, any Error>.makeStream()
        let payload = #"data: {"choices":[{"delta":{"content":"Olá"}}]}"# + ending + ending + "data: [DONE]" + ending
        for byte in payload.utf8 { bytes.continuation.yield(byte) }
        // Keep the transport open: DONE must finish consumption on its own.
        defer { bytes.continuation.finish() }
        let output = Mutex("")
        try await withOperationTimeout(.seconds(2), error: TranslationError.timedOut) {
            try await OpenAICompatibleTransformer.consumeSSE(bytes: bytes.stream, endpointHost: "fixture",
                inactivityTimeout: .seconds(30), inactivitySleeper: { try await Task.sleep(for: $0) },
                onDelta: { delta in output.withLock { $0 += delta } })
        }
        #expect(output.withLock { $0 } == "Olá")
    }

    private func consume(
        _ payload: String, byteLimit: Int = OpenAICompatibleTransformer.responseBodyLimit
    ) async throws -> String {
        let bytes = AsyncThrowingStream<UInt8, any Error>.makeStream()
        for byte in payload.utf8 { bytes.continuation.yield(byte) }
        bytes.continuation.finish()
        let output = Mutex("")
        try await withOperationTimeout(.seconds(2), error: TranslationError.timedOut) {
            try await OpenAICompatibleTransformer.consumeSSE(bytes: bytes.stream, endpointHost: "fixture",
                inactivityTimeout: .seconds(30), inactivitySleeper: { try await Task.sleep(for: $0) },
                byteLimit: byteLimit, onDelta: { delta in output.withLock { $0 += delta } })
        }
        return output.withLock { $0 }
    }

    @Test func aStreamThatEndsOnStopWithoutDoneSucceeds() async throws {
        let output = try await consume(
            #"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"# + "\n\n"
            + #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"# + "\n\n"
        )
        #expect(output == "Hi")
    }

    @Test func aStreamThatEndsWithoutStopOrDoneIsADroppedConnection() async throws {
        await #expect(throws: TranslationError.cannotConnect("fixture")) {
            _ = try await consume(#"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}]}"# + "\n\n")
        }
    }

    @Test func aFinalChunkWithoutADeltaIsAccepted() async throws {
        let output = try await consume(
            #"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n\n"
            + #"data: {"choices":[{"index":0,"finish_reason":"stop"}]}"# + "\n\n"
        )
        #expect(output == "Hi")
    }

    @Test(arguments: [
        #"data: {"choices":[{"delta":{},"finish_reason":"error"}]}"#,
        #"data: {"choices":[{"delta":{}}],"error":{"message":"upstream failed"}}"#,
        #"data: {"error":{"message":"upstream failed","code":502}}"#,
    ])
    func anErrorPartwayThroughIsAFailureEvenWhenDoneFollows(errorChunk: String) async throws {
        await #expect(throws: TranslationError.providerReportedError) {
            _ = try await consume(
                #"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n\n" + errorChunk + "\n\n" + "data: [DONE]\n\n"
            )
        }
    }

    /// Mistral's reasoning docs (https://docs.mistral.ai/capabilities/reasoning/, read 2026-11-14)
    /// describe the stream in prose and print no streamed JSON; these chunks are built from that
    /// description and its `ThinkChunk` and `TextChunk` types. While thinking, `delta.content` is a
    /// list holding a thinking chunk; at the transition, one list holds a closing thinking chunk and
    /// the first text chunk; the answer is a plain string. Thinking is progress, so a long think is not
    /// cut off, but never answer text.
    @Test func mistralThinkingChunksAreProgressButNotAnswerText() throws {
        var parser = OpenAISSEParser()
        let thinking = try parser.append(
            #"data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":"Plan the reply."}]}]}}]}"# + "\n"
        )
        #expect(thinking.isEmpty)
        #expect(parser.progressChunks == 1)

        let transition = try parser.append(
            #"data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":" Done."}]},{"type":"text","text":"Hello"}]}}]}"# + "\n"
        )
        #expect(transition == [.delta("Hello")])
        #expect(parser.progressChunks == 2)

        let answer = try parser.append(#"data: {"choices":[{"delta":{"content":" there."}}]}"# + "\n")
        #expect(answer == [.delta(" there.")])
        #expect(parser.progressChunks == 3)
    }

    /// The other side of the rule: chunks that carry nothing generated are not progress, so a server
    /// repeating them cannot hold a run open. A text part counts only by its text, whatever labels it
    /// carries beside it.
    @Test(arguments: [
        #"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
        #"data: {"choices":[{"delta":{"content":[{"type":"text","text":""}]}}]}"#,
        #"data: {"choices":[{"delta":{"content":[{"type":"text","text":"","id":"part_1"}]}}]}"#,
        #"data: {"choices":[{"delta":{"content":[{"type":"text","text":"","format":"markdown"}]}}]}"#,
        #"data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[]}]}}]}"#,
        #"data: {"choices":[{"delta":{"content":[{"type":"thinking","thinking":[{"type":"text","text":""}]}]}}]}"#,
        #"data: {"choices":[{"delta":{}}]}"#,
        // Hand-built: a number or a flag is not generated text.
        #"data: {"choices":[{"delta":{"x_partial":true}}]}"#,
        #"data: {"choices":[{"delta":{"x_tokens":3}}]}"#,
    ])
    func chunksCarryingNothingAreNotProgress(chunk: String) throws {
        var parser = OpenAISSEParser()
        #expect(try parser.append(chunk + "\n").isEmpty)
        #expect(parser.progressChunks == 0)
    }

    @Test func aChunkWithoutChoicesOrAnErrorIsSkipped() async throws {
        let output = try await consume(
            #"data: {"usage":{"prompt_tokens":3,"completion_tokens":1}}"# + "\n\n"
            + #"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n\n" + "data: [DONE]\n\n"
        )
        #expect(output == "Hi")
    }

    /// A 200 that never sends an event goes back to the caller, which decodes it as a plain answer or
    /// fails it as invalid. Only whitespace and comments mean the connection dropped.
    @Test func aReplyWithoutOneEventGoesBackToTheCallerUnlessItIsEmpty() async throws {
        let json = #"{"choices":[{"message":{"content":"Hi"}}]}"#
        await #expect(throws: OpenAICompatibleTransformer.NotAnEventStream(body: Data(json.utf8))) {
            _ = try await consume(json)
        }
        await #expect(throws: OpenAICompatibleTransformer.NotAnEventStream(body: Data("<html>\n</html>".utf8))) {
            _ = try await consume("<html>\n: not a comment in HTML, but skipped\n</html>")
        }
        for empty in ["", "\n\n", ": keepalive\n\n"] {
            await #expect(throws: TranslationError.cannotConnect("fixture")) { _ = try await consume(empty) }
        }
    }

    @Test func manySmallDeltasStopAtTheByteLimit() async throws {
        let chunk = #"data: {"choices":[{"delta":{"content":"again "}}]}"# + "\n\n"
        await #expect(throws: TranslationError.responseTooLarge) {
            _ = try await consume(String(repeating: chunk, count: 100) + "data: [DONE]\n\n", byteLimit: 2_000)
        }
        #expect(try await consume(String(repeating: chunk, count: 10) + "data: [DONE]\n\n", byteLimit: 2_000)
            == String(repeating: "again ", count: 10))
    }

    @Test func aLineThatNeverEndsStopsAtTheByteLimit() async throws {
        await #expect(throws: TranslationError.responseTooLarge) {
            _ = try await consume("data: " + String(repeating: "x", count: 5_000), byteLimit: 2_000)
        }
    }
}
