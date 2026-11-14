import Foundation
import Testing
@testable import Syrup

@MainActor
struct StreamingTypistTests {
    @Test(arguments: [1, 200])
    func requestedQuotesSurviveIncrementalAndForcedFlush(sizeThreshold: Int) async throws {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(poster: poster, sizeThreshold: sizeThreshold)
        try typist.start()
        typist.setKeepsWrapperQuotes(true)
        typist.append(#"  "hello"#)
        await typist.waitForQueuedFlushes()
        if sizeThreshold == 1 {
            #expect(poster.text == #""hel"#)
        } else {
            #expect(poster.text.isEmpty)
        }
        typist.append(#""  "#)
        await typist.finish()
        #expect(poster.text == #""hello""#)

        try typist.start()
        typist.append(#""hello""#)
        await typist.finish()
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
    func bufferSizeFlushesWithoutWaitingForCadence() async {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(poster: poster)
        try? typist.start()

        typist.append(String(repeating: "a", count: 202))
        await typist.waitForQueuedFlushes()

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
    ) async {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(poster: poster, sizeThreshold: 1)
        try? typist.start()

        typist.append(input)
        await typist.waitForQueuedFlushes()
        #expect(poster.text == prefix)

        await typist.finish()
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

        await typist.finish()
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
    func finishAppliesStreamingQuoteAndTailNormalization(input: String, expected: String) async {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(poster: poster)
        try? typist.start()

        typist.append(input)
        await typist.finish()

        #expect(poster.text == expected)
    }

    @Test
    func focusChangeStopsTypingPermanently() async {
        var frontmostID = "app-a"
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(
            poster: poster,
            frontmostApplicationID: { frontmostID }
        )
        try? typist.start()
        frontmostID = "app-b"

        typist.append(String(repeating: "a", count: 202))
        await typist.waitForQueuedFlushes()
        frontmostID = "app-a"
        typist.append(String(repeating: "b", count: 202))
        await typist.waitForQueuedFlushes()

        #expect(poster.text == "")
        #expect(typist.stopReason == .focusChanged)
    }

    @Test
    func unavailableInitialTargetPreventsEventPosting() async {
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(
            poster: poster,
            frontmostApplicationID: { nil }
        )

        #expect(throws: StreamingTypingStartError.targetUnavailable) {
            try typist.start()
        }
        typist.append(String(repeating: "a", count: 202))
        await typist.finish()

        #expect(poster.chunks.isEmpty)
        #expect(typist.hasPostedText == false)
    }

    @Test
    func secureInputAppearingMidStreamStopsTyping() async {
        var isSecureInputEnabled = false
        let poster = StreamingEventPosterSpy()
        let typist = makeTypist(
            poster: poster,
            secureInputStatus: { isSecureInputEnabled }
        )
        try? typist.start()
        isSecureInputEnabled = true

        typist.append(String(repeating: "a", count: 202))
        await typist.waitForQueuedFlushes()

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
    func splitCRLFDeltasProduceOneLineBreak() async throws {
        var steps: [TypingStep] = []
        let typist = StreamingTypist(sizeThreshold: 1, trustStatus: { true },
            secureInputStatus: { false }, frontmostApplicationID: { "fixture" },
            eventPoster: { steps.append($0); return true }, sleeper: { _ in })
        try typist.start()
        typist.append("first\r")
        typist.append("\nsecond")
        await typist.finish()
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
    func rechecksAppAndSecureInputBetweenSteps(secureInput: Bool) async throws {
        var frontmost = "fixture"
        var secure = false
        var steps: [TypingStep] = []
        let typist = StreamingTypist(trustStatus: { true },
            secureInputStatus: { secure }, frontmostApplicationID: { frontmost },
            eventPoster: {
                steps.append($0)
                if secureInput { secure = true } else { frontmost = "other" }
                return true
            }, sleeper: { _ in })
        try typist.start()
        typist.append("first\nsecond")
        await typist.finish()
        #expect(steps == [.text("first")])
        #expect(typist.stopReason == (secureInput ? .secureInputActive : .focusChanged))
    }

    @Test
    func checksTheFocusedFieldOncePerFlushNotPerStep() async throws {
        var validations = 0
        var steps: [TypingStep] = []
        let typist = StreamingTypist(trustStatus: { true },
            secureInputStatus: { false }, frontmostApplicationID: { "fixture" },
            eventPoster: { steps.append($0); return true }, sleeper: { _ in })
        typist.setTargetValidator { validations += 1; return true }
        try typist.start()
        typist.append("one\ntwo\nthree\nfour")
        await typist.finish()
        #expect(steps.count == 7)
        #expect(validations == 1)
    }

    @Test
    func aFieldChangeStopsTheNextFlush() async throws {
        let field = FieldFocus()
        var steps: [TypingStep] = []
        let typist = StreamingTypist(sizeThreshold: 1, trustStatus: { true },
            secureInputStatus: { false }, frontmostApplicationID: { "fixture" },
            eventPoster: { steps.append($0); return true }, sleeper: { _ in })
        typist.setTargetValidator { field.isSame }
        try typist.start()
        typist.append("first ")
        await typist.waitForQueuedFlushes()
        field.isSame = false
        typist.append("second ")
        await typist.finish()
        #expect(typist.stopReason == .focusChanged)
        #expect(steps.contains(.text("second")) == false)
    }

    /// The focus check may wait on Accessibility off the main actor. Deltas that arrive meanwhile
    /// queue behind it, and each flush still checks before it posts, so the text stays in order.
    @Test func aSlowFocusCheckKeepsTextInOrder() async throws {
        let gate = FocusCheckGate()
        var steps: [TypingStep] = []
        let typist = StreamingTypist(sizeThreshold: 1, trustStatus: { true },
            secureInputStatus: { false }, frontmostApplicationID: { "fixture" },
            eventPoster: { steps.append($0); return true }, sleeper: { _ in })
        typist.setTargetValidator { await gate.check() }
        try typist.start()
        typist.append("one two ")
        await eventually { gate.waiting == 1 }
        typist.append("three four ")
        typist.append("five")
        #expect(steps.isEmpty)
        gate.open()
        await typist.finish()
        #expect(steps.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined() == "one two three four five")
        #expect(gate.checks >= 2)
    }

    /// Esc cancels the typist while a focus check is still waiting: nothing is posted afterwards.
    @Test func cancelDuringAFocusCheckPostsNothing() async throws {
        let gate = FocusCheckGate()
        var steps: [TypingStep] = []
        let typist = StreamingTypist(sizeThreshold: 1, trustStatus: { true },
            secureInputStatus: { false }, frontmostApplicationID: { "fixture" },
            eventPoster: { steps.append($0); return true }, sleeper: { _ in })
        typist.setTargetValidator { await gate.check() }
        try typist.start()
        typist.append("private words")
        await eventually { gate.waiting == 1 }
        typist.cancel()
        gate.open()
        await typist.waitForQueuedFlushes()
        #expect(steps.isEmpty)
        #expect(typist.hasPostedText == false)
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

// The cadence task hops back to the main actor after its sleep resumes, so wait for the text.
@MainActor
private func expectPostedText(
    _ poster: StreamingEventPosterSpy,
    _ expected: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    await eventually(sourceLocation: sourceLocation) { poster.text == expected }
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

@MainActor
private final class FieldFocus {
    var isSame = true
}

/// A focus check that waits until the test answers it, like an Accessibility read of a slow app.
@MainActor
private final class FocusCheckGate {
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var isOpen = false
    private(set) var checks = 0
    var waiting: Int { waiters.count }

    func check() async -> Bool {
        checks += 1
        if isOpen { return true }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Answers the waiting checks, and every later one, with "still focused".
    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume(returning: true) }
    }
}
