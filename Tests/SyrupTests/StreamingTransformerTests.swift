import Foundation
import Testing
@testable import Syrup

struct StreamingTransformerTests {
    @Test
    func sseParserReassemblesLinesSplitAcrossChunks() throws {
        var parser = OpenAISSEParser()

        let firstEvents = try parser.append(
            #"data: {"choices":[{"delta":{"content":"Good"#
        )
        let secondEvents = try parser.append(
            #" morning"}}]}"# + "\n\n" +
            "data: [DONE]\n\n"
        )

        #expect(firstEvents.isEmpty)
        #expect(secondEvents == [.delta("Good morning"), .done])
    }

    @Test
    func sseParserSkipsEmptyAndRoleOnlyDeltas() throws {
        var parser = OpenAISSEParser()

        let events = try parser.append(
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"# + "\n" +
            #"data: {"choices":[{"delta":{"content":""}}]}"# + "\n"
        )

        #expect(events.isEmpty)
    }

    @Test
    func sseParserRejectsMalformedDataEvents() {
        var parser = OpenAISSEParser()

        #expect(throws: TranslationError.invalidResponse) {
            _ = try parser.append("data: {not-json}\n")
        }
    }

    @Test
    func sseParserIgnoresCommentsAndUnknownFields() throws {
        var parser = OpenAISSEParser()

        let events = try parser.append(
            ": keepalive\n" +
            #"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":null}],"id":"1"}"# + "\n"
        )

        #expect(events == [.delta("Hi")])
    }

    @Test
    func cumulativeSnapshotAdapterEmitsOnlyNewSuffixes() {
        var adapter = CumulativeSnapshotDeltaAdapter()

        #expect(adapter.append("Good") == .delta("Good"))
        #expect(adapter.append("Good morning") == .delta(" morning"))
        #expect(adapter.append("Good morning") == .delta(""))
    }

    @Test
    func cumulativeSnapshotAdapterSignalsNonExtension() {
        var adapter = CumulativeSnapshotDeltaAdapter()
        _ = adapter.append("Good morning")

        #expect(adapter.append("Hello") == .requiresAtomicFallback)
    }

    @Test
    func inactivityDeadlineIgnoresNonDeltaTrafficAndInterruptsAnOpenStream() async {
        let bytes = AsyncThrowingStream<UInt8, any Error>.makeStream()
        let lines = AsyncStream<Void>.makeStream()
        var lineIterator = lines.stream.makeAsyncIterator()
        let sleeper = ManualStreamingInactivitySleeper()
        let task = Task {
            try await OpenAICompatibleTransformer.consumeSSE(
                bytes: bytes.stream,
                endpointHost: "example.com",
                inactivityTimeout: .seconds(30),
                inactivitySleeper: { duration in
                    try await sleeper.sleep(for: duration)
                },
                lineObserver: {
                    lines.continuation.yield()
                },
                onDelta: { _ in }
            )
        }

        await sleeper.waitForCallCount(1)
        yield(
            #"data: {"choices":[{"delta":{"content":"Hi"}}]}"# + "\n",
            to: bytes.continuation
        )
        _ = await lineIterator.next()
        await sleeper.waitForCallCount(2)
        let requestedDurations = await sleeper.requestedDurations
        #expect(requestedDurations == [.seconds(30), .seconds(30)])

        // A keepalive just before the content deadline is transport activity,
        // but it must not extend the deadline established by the last delta.
        yield(": keepalive\n", to: bytes.continuation)
        _ = await lineIterator.next()
        let callCount = await sleeper.callCount
        #expect(callCount == 2)

        await sleeper.resumeLatest()
        await #expect(throws: TranslationError.timedOut) {
            try await task.value
        }
        bytes.continuation.finish()
        lines.continuation.finish()
    }

    /// A model that reasons before it answers sends chunks without `content`. They are progress, so
    /// they reset the deadline that only a stalled stream should reach.
    @Test
    func aChunkWithoutAnswerTextStillResetsTheInactivityDeadline() async {
        let bytes = AsyncThrowingStream<UInt8, any Error>.makeStream()
        let lines = AsyncStream<Void>.makeStream()
        var lineIterator = lines.stream.makeAsyncIterator()
        let sleeper = ManualStreamingInactivitySleeper()
        let task = Task {
            try await OpenAICompatibleTransformer.consumeSSE(
                bytes: bytes.stream,
                endpointHost: "example.com",
                inactivityTimeout: .seconds(30),
                inactivitySleeper: { duration in
                    try await sleeper.sleep(for: duration)
                },
                lineObserver: {
                    lines.continuation.yield()
                },
                onDelta: { _ in }
            )
        }

        await sleeper.waitForCallCount(1)
        yield(#"data: {"choices":[{"delta":{"reasoning_content":"Thinking"}}]}"# + "\n", to: bytes.continuation)
        _ = await lineIterator.next()
        await sleeper.waitForCallCount(2)
        yield(#"data: {"choices":[{"delta":{"reasoning":"More"}}]}"# + "\n", to: bytes.continuation)
        _ = await lineIterator.next()
        await sleeper.waitForCallCount(3)
        #expect(await sleeper.callCount == 3)

        yield(#"data: {"choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}"# + "\n", to: bytes.continuation)
        bytes.continuation.finish()
        lines.continuation.finish()
        await #expect(throws: Never.self) { try await task.value }
    }

    /// Chunks with no text, repeated by a buggy server, must not hold a run open: only the chunk with
    /// reasoning text after them resets the deadline.
    @Test
    func chunksWithoutTextDoNotResetTheInactivityDeadline() async {
        let bytes = AsyncThrowingStream<UInt8, any Error>.makeStream()
        let lines = AsyncStream<Void>.makeStream()
        var lineIterator = lines.stream.makeAsyncIterator()
        let sleeper = ManualStreamingInactivitySleeper()
        let task = Task {
            try await OpenAICompatibleTransformer.consumeSSE(
                bytes: bytes.stream,
                endpointHost: "example.com",
                inactivityTimeout: .seconds(30),
                inactivitySleeper: { duration in
                    try await sleeper.sleep(for: duration)
                },
                lineObserver: {
                    lines.continuation.yield()
                },
                onDelta: { _ in }
            )
        }

        await sleeper.waitForCallCount(1)
        for empty in [
            #"data: {}"#, #"data: {"usage":{"total_tokens":3}}"#, #"data: {"choices":[{"delta":{}}]}"#,
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#, #"data: {"choices":[{"delta":{"content":""}}]}"#,
        ] {
            yield(empty + "\n", to: bytes.continuation)
            _ = await lineIterator.next()
        }
        yield(#"data: {"choices":[{"delta":{"reasoning_content":"Thinking"}}]}"# + "\n", to: bytes.continuation)
        _ = await lineIterator.next()
        await sleeper.waitForCallCount(2)
        await Task { @MainActor in }.value
        #expect(await sleeper.callCount == 2)

        await sleeper.resumeLatest()
        await #expect(throws: TranslationError.timedOut) { try await task.value }
        bytes.continuation.finish()
        lines.continuation.finish()
    }

    @Test
    func doneStopsConsumptionBeforeBufferedTransportFailure() async throws {
        let bytes = AsyncThrowingStream<UInt8, any Error>.makeStream()
        let sleeper = ManualStreamingInactivitySleeper()
        yield("data: [DONE]\n", to: bytes.continuation)
        bytes.continuation.finish(throwing: PostDoneTransportError.consumedPastDone)

        try await OpenAICompatibleTransformer.consumeSSE(
            bytes: bytes.stream,
            endpointHost: "example.com",
            inactivityTimeout: .seconds(30),
            inactivitySleeper: { duration in
                try await sleeper.sleep(for: duration)
            },
            onDelta: { _ in }
        )
    }
}

private enum PostDoneTransportError: Error {
    case consumedPastDone
}

private func yield(
    _ text: String,
    to continuation: AsyncThrowingStream<UInt8, any Error>.Continuation
) {
    for byte in text.utf8 {
        continuation.yield(byte)
    }
}

private actor ManualStreamingInactivitySleeper {
    private var nextID = 0
    private var calls: [(id: Int, duration: Duration)] = []
    private var continuations: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var callCount: Int {
        calls.count
    }

    var requestedDurations: [Duration] {
        calls.map(\.duration)
    }

    func sleep(for duration: Duration) async throws {
        let id = nextID
        nextID += 1
        calls.append((id, duration))
        resumeSatisfiedCallWaiters()

        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelCall(id) }
        }
    }

    func waitForCallCount(_ expectedCount: Int) async {
        if calls.count >= expectedCount { return }

        await withCheckedContinuation { continuation in
            callWaiters.append((expectedCount, continuation))
        }
    }

    func resumeLatest() {
        guard let id = calls.last?.id else { return }
        continuations.removeValue(forKey: id)?.resume()
    }

    private func cancelCall(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func resumeSatisfiedCallWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in callWaiters {
            if calls.count >= waiter.0 {
                waiter.1.resume()
            } else {
                pending.append(waiter)
            }
        }
        callWaiters = pending
    }
}
