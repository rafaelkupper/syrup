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
