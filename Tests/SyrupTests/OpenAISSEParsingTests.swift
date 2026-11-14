import AVFoundation
import Foundation
import KeyboardShortcuts
import Synchronization
import Testing
@testable import Syrup

/// Server-sent event parsing for streamed OpenAI-compatible replies.
@MainActor
struct OpenAISSEParsingTests {
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
}
