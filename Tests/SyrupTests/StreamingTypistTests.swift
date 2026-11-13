import Foundation
import Testing
@testable import Syrup

@MainActor
struct StreamingTypistTests {
    @Test(arguments: [1, 200])
    func requestedQuotesSurviveIncrementalAndForcedFlush(sizeThreshold: Int) throws {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(poster: poster, sizeThreshold: sizeThreshold)
        try typist.start()
        typist.setKeepsWrapperQuotes(true)
        typist.append(#"  "hello"#)
        if sizeThreshold == 1 {
            #expect(poster.text == #""hel"#)
        } else {
            #expect(poster.text.isEmpty)
        }
        typist.append(#""  "#)
        typist.finish()
        #expect(poster.text == #""hello""#)

        try typist.start()
        typist.append(#""hello""#)
        typist.finish()
        #expect(poster.text == #""hello"hello"#)
    }

    @Test
    func cadenceCoalescesDeltasAndKeepsTwoCharacterTail() async {
        let sleeper = ManualStreamingTypistSleeper()
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(
            poster: poster,
            sleeper: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
        try? typist.start()

        typist.append("abc")
        typist.append("def")
        #expect(poster.text == "")

        await sleeper.waitForCall()
        await sleeper.resume()

        await expectPostedText(poster, "abcd")
    }

    @Test
    func bufferSizeFlushesWithoutWaitingForCadence() {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(poster: poster)
        try? typist.start()

        typist.append(String(repeating: "a", count: 202))

        #expect(poster.text == String(repeating: "a", count: 200))
        #expect(typist.hasPostedText)
        typist.cancel()
        #expect(typist.hasPostedText)
    }

    @Test(arguments: [
        (#""Hello"   "#, "", "Hello"),
        (#""Hello   "#, "", #""Hello"#),
        ("Hello   ", "Hell", "Hello"),
        (#"Hello""#, "Hell", #"Hello""#),
        (#"""#, "", ""),
    ])
    func sizeThresholdRetainsUndecidedQuoteAndWhitespaceSuffix(
        input: String,
        prefix: String,
        expected: String
    ) {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(poster: poster, sizeThreshold: 1)
        try? typist.start()

        typist.append(input)
        #expect(poster.text == prefix)

        typist.finish()
        #expect(poster.text == expected)
        #expect(poster.text == ModelOutputNormalizer.normalize(input))
        #expect(typist.hasPostedText == (expected.isEmpty == false))
    }

    @Test(arguments: [
        (#""Hello"   "#, "", "Hello"),
        (#""Hello   "#, "", #""Hello"#),
        ("Hello   ", "Hell", "Hello"),
        (#"Hello""#, "Hell", #"Hello""#),
        (#""   "#, "", ""),
    ])
    func cadenceRetainsUndecidedQuoteAndWhitespaceSuffix(
        input: String,
        prefix: String,
        expected: String
    ) async {
        let sleeper = ManualStreamingTypistSleeper()
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(
            poster: poster,
            sleeper: { duration in
                try await sleeper.sleep(for: duration)
            }
        )
        try? typist.start()

        typist.append(input)
        await sleeper.waitForCall()
        await sleeper.resume()
        await expectPostedText(poster, prefix)

        typist.finish()
        #expect(poster.text == expected)
        #expect(poster.text == ModelOutputNormalizer.normalize(input))
        #expect(typist.hasPostedText == (expected.isEmpty == false))
    }

    @Test(arguments: [
        (#""Hello""#, "Hello"),
        ("Hello", "Hello"),
        (#""Hello"#, #""Hello"#),
        (#"Hello""#, #"Hello""#),
        (#"""#, ""),
        ("  Hello  ", "Hello"),
    ])
    func finishAppliesStreamingQuoteAndTailNormalization(input: String, expected: String) {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(poster: poster)
        try? typist.start()

        typist.append(input)
        typist.finish()

        #expect(poster.text == expected)
    }

    @Test
    func focusChangeStopsTypingPermanently() {
        var frontmostID = "app-a"
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(
            poster: poster,
            frontmostApplicationID: { frontmostID }
        )
        try? typist.start()
        frontmostID = "app-b"

        typist.append(String(repeating: "a", count: 202))
        frontmostID = "app-a"
        typist.append(String(repeating: "b", count: 202))

        #expect(poster.text == "")
        #expect(typist.stopReason == .focusChanged)
    }

    @Test
    func unavailableInitialTargetPreventsEventPosting() {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(
            poster: poster,
            frontmostApplicationID: { nil }
        )

        #expect(throws: StreamingTypingStartError.targetUnavailable) {
            try typist.start()
        }
        typist.append(String(repeating: "a", count: 202))
        typist.finish()

        #expect(poster.chunks.isEmpty)
        #expect(typist.hasPostedText == false)
    }

    @Test
    func secureInputAppearingMidStreamStopsTyping() {
        var isSecureInputEnabled = false
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(
            poster: poster,
            secureInputStatus: { isSecureInputEnabled }
        )
        try? typist.start()
        isSecureInputEnabled = true

        typist.append(String(repeating: "a", count: 202))

        #expect(poster.text == "")
        #expect(typist.stopReason == .secureInputActive)
    }

    @Test
    func unicodeChunksNeverSplitSurrogatePairsOrGraphemes() {
        let input = String(repeating: "a", count: 19) + "👨‍👩‍👧‍👦" + "é" + String(repeating: "b", count: 20)

        let chunks = TypingStep.plan(input).compactMap { step -> String? in
            if case .text(let text) = step { return text }
            return nil
        }

        #expect(chunks.joined() == input)
        #expect(chunks.allSatisfy { $0.utf16.count <= 20 })
    }

    @Test
    func mixedTextUsesExplicitLineBreaks() {
        #expect(TypingStep.plan("one\ntwo\r\nthree\rfour\n\nfive") == [
            .text("one"), .lineBreak, .text("two"), .lineBreak,
            .text("three"), .lineBreak, .text("four"), .lineBreak,
            .lineBreak, .text("five")
        ])
        #expect(TypingStep.plan("").isEmpty)
    }

    @Test
    func surrogateAtChunkBoundaryStaysIntact() {
        let prefix = String(repeating: "a", count: 19)
        #expect(TypingStep.plan(prefix + "😀b\r\nend") == [
            .text(prefix), .text("😀b"), .lineBreak, .text("end")
        ])
    }

    @Test
    func splitCRLFDeltasProduceOneLineBreak() throws {
        var steps: [TypingStep] = []
        let typist = StreamingTypist(sizeThreshold: 1, trustStatus: { true },
            secureInputStatus: { false }, frontmostApplicationID: { "fixture" },
            eventPoster: { steps.append($0); return true }, sleeper: { _ in })
        try typist.start()
        typist.append("first\r")
        typist.append("\nsecond")
        typist.finish()
        #expect(steps.filter { $0 == .lineBreak }.count == 1)
        let delivered = steps.map { step in
            switch step {
            case .text(let text): text
            case .lineBreak: "\n"
            }
        }.joined()
        #expect(delivered == "first\nsecond")
    }

    @Test(arguments: [false, true])
    func rechecksTargetAndSecureInputBetweenSteps(secureInput: Bool) throws {
        var sameTarget = true
        var secure = false
        var steps: [TypingStep] = []
        let typist = StreamingTypist(trustStatus: { true },
            secureInputStatus: { secure }, frontmostApplicationID: { "fixture" },
            eventPoster: {
                steps.append($0)
                if secureInput { secure = true } else { sameTarget = false }
                return true
            }, sleeper: { _ in })
        typist.setTargetValidator { sameTarget }
        try typist.start()
        typist.append("first\nsecond")
        typist.finish()
        #expect(steps == [.text("first")])
        #expect(typist.stopReason == (secureInput ? .secureInputActive : .focusChanged))
    }

    private func makeTypist(
        poster: StreamingEventPosterSpy,
        sleeper: @escaping StreamingTypistSleeper = { _ in },
        frontmostApplicationID: @escaping () -> String? = { "app-a" },
        secureInputStatus: @escaping () -> Bool = { false },
        sizeThreshold: Int = 200
    ) -> StreamingTypist {
        StreamingTypist(
            cadence: .milliseconds(50),
            sizeThreshold: sizeThreshold,
            trustStatus: { true },
            secureInputStatus: secureInputStatus,
            frontmostApplicationID: frontmostApplicationID,
            eventPoster: poster.post,
            sleeper: sleeper
        )
    }
}

// The cadence task hops back to the main actor after its sleep resumes, so
// give the scheduler bounded yields instead of racing it with a single one.
@MainActor
private func expectPostedText(
    _ poster: StreamingEventPosterSpy,
    _ expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    for _ in 0..<200 {
        if poster.text == expected {
            break
        }
        await Task.yield()
    }
    #expect(poster.text == expected, sourceLocation: sourceLocation)
}

@MainActor
private final class StreamingEventPosterSpy {
    private(set) var chunks: [String] = []

    var text: String {
        chunks.joined()
    }

    func post(_ step: TypingStep) -> Bool {
        switch step {
        case .text(let text): chunks.append(text)
        case .lineBreak: chunks.append("\n")
        }
        return true
    }
}

private actor ManualStreamingTypistSleeper {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var callWaiter: CheckedContinuation<Void, Never>?

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    // Store the continuation BEFORE signaling waitForCall, so a
                    // resume() that follows waitForCall() always finds it.
                    self.continuation = continuation
                    callWaiter?.resume()
                    callWaiter = nil
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func waitForCall() async {
        if continuation != nil { return }
        await withCheckedContinuation { continuation in
            callWaiter = continuation
        }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }

    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
