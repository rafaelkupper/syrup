import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// Successful delivery: clipboard, history, auto-paste, streamed typing, and Paste Last.
@MainActor
struct AppStateDeliveryTests {
    @Test
    func successWritesTranslatedTextExactlyOnce() async {
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(pasteboard: pasteboard, feedback: feedback)

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])
        #expect(state.pipelineState == .idle)
        #expect(state.lastResult == "Good morning, how are you?")
        #expect(feedback.successSoundCount == 1)
        #expect(state.menuBarSymbol == "checkmark.circle")
    }

    @Test
    func successfulRunAppendsHistoryRecord() async throws {
        let history = HistoryStore()
        let pasteboard = SpyPasteboard()
        let state = makeState(pasteboard: pasteboard, history: history)

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])
        await expectHistoryCount(history, 1)
        let record = try #require(history.records.first)
        #expect(record.transcript == "bom dia, tudo bem?")
        #expect(record.output == "Good morning, how are you?")
        #expect(record.transformation == .translation(targetLanguage: "English", toneInstruction: ""))
        #expect(record.outcome == .success)
    }

    @Test
    func autoPasteRunsAfterClipboardWriteWhenEnabled() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        let pasteboard = SpyPasteboard()
        let autoPaster = SpyAutoPaster()
        let metrics = SpyPipelineMetrics()
        let state = makeState(
            settings: settings,
            pasteboard: pasteboard,
            metrics: metrics,
            autoPaster: autoPaster
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])
        await expectAutoPasteCompleted(autoPaster, metrics: metrics)
    }

    @Test
    func autoPasteFailureDegradesWithoutFailingRun() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let autoPaster = SpyAutoPaster(isTrusted: false, pasteError: AutoPasteError.notTrusted)
        let state = makeState(
            settings: settings,
            pasteboard: pasteboard,
            feedback: feedback,
            autoPaster: autoPaster
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])
        await expectState(state, .idle)
        #expect(feedback.autoPasteNotTrustedCount == 1)
        #expect(state.lastResult == "Good morning, how are you?")
    }

    @Test
    func disabledStreamingSettingUsesAtomicDelivery() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = false
        let typist = SpyStreamingTypist()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                atomicOutput: "Atomic result",
                deltas: ["Streamed result"]
            ),
            pasteboard: pasteboard,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Atomic result"])
        #expect(typist.startCount == 0)
    }

    @Test
    func disabledAutoPasteUsesAtomicDelivery() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = false
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                atomicOutput: "Atomic result",
                deltas: ["Streamed result"]
            ),
            pasteboard: pasteboard,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Atomic result"])
        #expect(typist.startCount == 0)
    }

    @Test
    func transformerWithoutStreamingCapabilityUsesAtomicDelivery() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            transformer: FakeTextTransformer(.success("Atomic result")),
            pasteboard: pasteboard,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Atomic result"])
        #expect(typist.startCount == 0)
    }

    @Test
    func missingAccessibilityTrustUsesAtomicDelivery() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                atomicOutput: "Atomic result",
                deltas: ["Streamed result"]
            ),
            pasteboard: pasteboard,
            autoPaster: SpyAutoPaster(isTrusted: false),
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Atomic result"])
        #expect(typist.startCount == 0)
    }

    @Test
    func secureInputAtStreamStartUsesAtomicDelivery() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        typist.startError = .secureInputActive
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                atomicOutput: "Atomic result",
                deltas: ["Streamed result"]
            ),
            pasteboard: pasteboard,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Atomic result"])
        #expect(typist.startCount == 1)
        #expect(typist.appendedDeltas.isEmpty)
    }

    @Test(arguments: [
        ("first\r\nsecond", [TypingStep.text("first"), .lineBreak, .text("second")]),
        ("'kept'", [TypingStep.text("'kept'")])
    ])
    func chromiumTypesCompletedOutputAndWritesClipboardOnce(output: String, expectedSteps: [TypingStep]) async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = false
        let autoPaster = SpyAutoPaster()
        autoPaster.strategy = .typeText
        var posted: [TypingStep] = []
        let typist = StreamingTypist(trustStatus: { true }, secureInputStatus: { false },
            frontmostApplicationID: { "fixture" },
            eventPoster: { posted.append($0); return true })
        let pasteboard = SpyPasteboard()
        let state = makeState(settings: settings,
            transformer: FakeTextTransformer(.success(output)), pasteboard: pasteboard,
            autoPaster: autoPaster, streamingTypistFactory: { typist })
        state.triggerPressed()
        state.triggerReleased()
        await expectState(state, .idle)
        #expect(pasteboard.writes == [output])
        #expect(posted == expectedSteps)
        #expect(autoPaster.pasteCount == 0)
    }

    @Test(arguments: [StreamingTypingStopReason.focusChanged, .secureInputActive, .eventCreationFailed])
    func chromiumTypingFailureKeepsClipboardAndSuccessfulRun(reason: StreamingTypingStopReason) async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        let autoPaster = SpyAutoPaster()
        autoPaster.strategy = .typeText
        let typist = SpyStreamingTypist()
        typist.stopAfterFirstAppend = reason
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(settings: settings, pasteboard: pasteboard, feedback: feedback,
            autoPaster: autoPaster, streamingTypistFactory: { typist })
        state.triggerPressed()
        state.triggerReleased()
        await expectState(state, .idle)
        #expect(pasteboard.writes == ["Good morning, how are you?"])
        #expect(state.lastResult == "Good morning, how are you?")
        #expect(autoPaster.pasteCount == 0)
        #expect(typist.startCount == 1)
        if reason == .secureInputActive {
            #expect(feedback.autoPasteSecureInputCount == 1)
        } else {
            #expect(feedback.errorMessages.count == 1)
        }
    }

    @Test(arguments: [AutoPasteError.notTrusted, .secureInputActive, .eventCreationFailed])
    func chromiumTypingStartFailureKeepsClipboard(error: AutoPasteError) async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        let autoPaster = SpyAutoPaster()
        autoPaster.strategy = .typeText
        let typist = SpyStreamingTypist()
        typist.startError = error
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(settings: settings, pasteboard: pasteboard, feedback: feedback,
            autoPaster: autoPaster, streamingTypistFactory: { typist })
        state.triggerPressed()
        state.triggerReleased()
        await expectState(state, .idle)
        #expect(pasteboard.writes == ["Good morning, how are you?"])
        #expect(typist.appendedDeltas.isEmpty)
        #expect(autoPaster.pasteCount == 0)
        switch error {
        case .notTrusted: #expect(feedback.autoPasteNotTrustedCount == 1)
        case .secureInputActive: #expect(feedback.autoPasteSecureInputCount == 1)
        case .eventCreationFailed: #expect(feedback.errorMessages.count == 1)
        }
    }

    @Test(arguments: [PasteStrategy.commandV(9), .typeText], [true, false])
    func pasteLastUsesExistingDeliveryAndPreservesHistory(strategy: PasteStrategy, trusted: Bool) async {
        let clipboard = SpyPasteboard(), paster = SpyAutoPaster(isTrusted: trusted,
            pasteError: trusted ? nil : AutoPasteError.notTrusted)
        paster.strategy = strategy
        let feedback = SpyFeedback(), typist = SpyStreamingTypist()
        if !trusted { typist.startError = AutoPasteError.notTrusted }
        let history = HistoryStore()
        history.append(successfulRecord(output: "last success"))
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        // Without Accessibility no editor can be captured, as in the app.
        let state = makeState(settings: settings, pasteboard: clipboard, feedback: feedback, history: history,
                              autoPaster: paster, streamingTypistFactory: { typist },
                              captureDeliveryTarget: { _ in trusted ? DeliveryTarget(checkCurrent: { true }) : nil })
        await state.pasteLastResult()
        #expect(clipboard.writes == ["last success"])
        #expect(history.records.count == 1)
        if trusted {
            if strategy == .typeText { #expect(typist.appendedDeltas == ["last success"]) }
            else { #expect(paster.pasteCount == 1) }
        } else { #expect(feedback.autoPasteNotTrustedCount == 1) }
        state.triggerPressed()
        #expect(state.pipelineState == .recording)
        await state.pasteLastResult()
        #expect(clipboard.writes.count == 1)
    }

    @Test(arguments: [true, false])
    func aRunWithNoCapturedEditorSaysWhyInsteadOfEditorChanged(trusted: Bool) async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.pinDeliveryTarget = true
        let pasteboard = SpyPasteboard(), feedback = SpyFeedback(), paster = SpyAutoPaster(isTrusted: trusted)
        let state = makeState(settings: settings, pasteboard: pasteboard, feedback: feedback,
                              autoPaster: paster, captureDeliveryTarget: { _ in nil })
        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])
        await expectState(state, .idle)
        #expect(paster.pasteCount == 0)
        if trusted {
            #expect(feedback.errorMessages == ["No text field had focus - the result was copied."])
        } else {
            #expect(feedback.autoPasteNotTrustedCount == 1)
            #expect(feedback.errorMessages.isEmpty)
        }
    }

    @Test(arguments: [true, false])
    func pasteLastWithNoCapturedEditorSaysWhyInsteadOfEditorChanged(trusted: Bool) async {
        let history = HistoryStore()
        history.append(successfulRecord(output: "last success"))
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.pinDeliveryTarget = true
        let clipboard = SpyPasteboard(), feedback = SpyFeedback(), paster = SpyAutoPaster(isTrusted: trusted)
        let typist = SpyStreamingTypist()
        let state = makeState(settings: settings, pasteboard: clipboard, feedback: feedback, history: history,
                              autoPaster: paster, streamingTypistFactory: { typist },
                              captureDeliveryTarget: { _ in nil })
        await state.pasteLastResult()
        #expect(clipboard.writes == ["last success"])
        #expect(paster.pasteCount == 0)
        #expect(typist.appendedDeltas.isEmpty)
        if trusted {
            #expect(feedback.errorMessages == ["No text field had focus - the result was copied."])
        } else {
            #expect(feedback.autoPasteNotTrustedCount == 1)
            #expect(feedback.errorMessages.isEmpty)
        }
    }

    @Test func withAutomaticPasteOffPasteLastOnlyCopies() async {
        let history = HistoryStore()
        history.append(successfulRecord(output: "last success"))
        let clipboard = SpyPasteboard(), paster = SpyAutoPaster(), typist = SpyStreamingTypist()
        let settings = makeTestSettings()
        settings.autoPasteEnabled = false
        let state = makeState(settings: settings, pasteboard: clipboard, history: history,
                              autoPaster: paster, streamingTypistFactory: { typist })
        await state.pasteLastResult()
        #expect(clipboard.writes == ["last success"])
        #expect(paster.pasteCount == 0)
        #expect(typist.appendedDeltas.isEmpty)
        #expect(history.records.count == 1)
    }

    @Test func pasteLastDelayCannotPostIntoANewRun() async {
        let history = HistoryStore()
        history.append(successfulRecord(output: "previous"))
        let clipboard = SpyPasteboard(), paster = SpyAutoPaster()
        let sleeper = ManualResetSleeper()
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        let state = makeState(settings: settings, transcriber: FakeTranscriber(.suspended), pasteboard: clipboard,
                              history: history, autoPaster: paster,
                              autoPasteSleeper: { try await sleeper.sleep(nanoseconds: $0) })
        let paste = Task { await state.pasteLastResult() }
        await sleeper.waitForCallCount(1)
        state.triggerPressed()
        await sleeper.resumeCall(0)
        await paste.value
        #expect(clipboard.writes == ["previous"])
        #expect(paster.pasteCount == 0)
        state.cancelRequested()
    }

    @Test(arguments: [false, true])
    func successfulStreamTypesDeltasWritesClipboardOnceAndSkipsAtomicPaste(chromium: Bool) async throws {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        typist.postsTextOnAppend = true
        let pasteboard = SpyPasteboard()
        let autoPaster = SpyAutoPaster()
        autoPaster.strategy = chromium ? .typeText : .commandV(9)
        let metrics = SpyPipelineMetrics()
        let history = HistoryStore()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                atomicOutput: "Atomic result",
                deltas: ["\"Good", " morning\" "]
            ),
            pasteboard: pasteboard,
            metrics: metrics,
            history: history,
            autoPaster: autoPaster,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Good morning"])
        await expectHistoryCount(history, 1)
        let record = try #require(history.records.first)
        #expect(typist.appendedDeltas == ["\"Good", " morning\" "])
        #expect(typist.finishCount == 1)
        #expect(typist.startCount == 1)
        #expect(autoPaster.pasteCount == 0)
        #expect(record.output == "Good morning")
        #expect(metrics.endedStages.contains(.streamingFirstDelta))
        #expect(metrics.deliveryModes == [.streamed])
    }

    @Test(arguments: [
        ("In quotes hello.", true, #""hello""#),
        ("Entre aspas bom dia.", true, #""hello""#),
        ("Say hello.", true, "hello"),
        ("In quotes hello.", false, "hello"),
    ])
    func streamDeliveryPreservesOnlyRequestedQuotes(input: String, formatting: Bool, expected: String) async {
        let settings = makeTestSettings()
        settings.translationProvider = .openAICompatible
        settings.handlesSpokenFormatting = formatting
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let pasteboard = SpyPasteboard()
        var typedText = ""
        let typist = StreamingTypist(
            sizeThreshold: 1,
            trustStatus: { true },
            secureInputStatus: { false },
            frontmostApplicationID: { "test-editor" },
            eventPoster: { step in
                if case .text(let text) = step { typedText += text }
                return true
            }
        )
        let state = makeState(
            settings: settings,
            transcriber: FakeTranscriber(.success(input)),
            transformer: FakeStreamingTextTransformer(deltas: [#""hel"#, #"lo""#]),
            pasteboard: pasteboard,
            streamingTypistFactory: { typist }
        )
        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, [expected])
        #expect(typedText == expected)
        #expect(state.lastResult == expected)
    }

    @Test
    func focusChangeDowngradesToClipboardOnlyCompletion() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        typist.stopAfterFirstAppend = .focusChanged
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let autoPaster = SpyAutoPaster()
        let metrics = SpyPipelineMetrics()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(deltas: ["Good", " morning"]),
            pasteboard: pasteboard,
            feedback: feedback,
            metrics: metrics,
            autoPaster: autoPaster,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Good morning"])
        #expect(feedback.streamingFocusChangedCount == 1)
        #expect(autoPaster.pasteCount == 0)
        #expect(metrics.deliveryModes == [.streamedPartial])
    }

    @Test
    func nonAppendOnlyStreamBeforeAnyPostUsesAtomicPasteFallback() async throws {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            continuation.yield("Buffered prefix")
            continuation.finish(throwing: StreamingTransformError.requiresAtomicFallback)
        }
        let typist = SpyStreamingTypist()
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let feedback = SpyFeedback()
        let autoPaster = SpyAutoPaster()
        let metrics = SpyPipelineMetrics()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                atomicOutput: "Clean atomic result",
                stream: stream
            ),
            pasteboard: pasteboard,
            feedback: feedback,
            metrics: metrics,
            history: history,
            autoPaster: autoPaster,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Clean atomic result"])
        await expectHistoryCount(history, 1)
        await expectState(state, .idle)
        let record = try #require(history.records.first)
        #expect(typist.appendedDeltas == ["Buffered prefix"])
        #expect(typist.hasPostedText == false)
        #expect(typist.cancelCount == 1)
        #expect(autoPaster.pasteCount == 1)
        #expect(record.output == "Clean atomic result")
        #expect(metrics.deliveryModes == [.atomic])
        #expect(feedback.errorMessages.isEmpty)
    }

    @Test
    func nonAppendOnlyStreamAfterVisiblePrefixUsesClipboardOnlyFallback() async throws {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let stream = AsyncThrowingStream<String, any Error> { continuation in
            continuation.yield("Typed prefix")
            continuation.finish(throwing: StreamingTransformError.requiresAtomicFallback)
        }
        let typist = SpyStreamingTypist()
        typist.postsTextOnAppend = true
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let feedback = SpyFeedback()
        let autoPaster = SpyAutoPaster()
        let metrics = SpyPipelineMetrics()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                atomicOutput: "Clean atomic result",
                stream: stream
            ),
            pasteboard: pasteboard,
            feedback: feedback,
            metrics: metrics,
            history: history,
            autoPaster: autoPaster,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Clean atomic result"])
        await expectHistoryCount(history, 1)
        await expectState(state, .idle)
        let record = try #require(history.records.first)
        #expect(typist.appendedDeltas == ["Typed prefix"])
        #expect(typist.hasPostedText)
        #expect(typist.cancelCount == 1)
        #expect(typist.finishCount == 0)
        #expect(autoPaster.pasteCount == 0)
        #expect(record.output == "Clean atomic result")
        #expect(metrics.deliveryModes == [.streamedPartial])
        #expect(feedback.errorMessages == ["Streaming stopped - the full result was copied."])
    }

    @Test
    func midStreamProviderErrorWritesNoClipboardAndRecordsFailure() async throws {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        typist.postsTextOnAppend = true
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let feedback = SpyFeedback()
        let metrics = SpyPipelineMetrics()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                deltas: ["Partial"],
                terminalError: .transformer
            ),
            pasteboard: pasteboard,
            feedback: feedback,
            metrics: metrics,
            history: history,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(
            state,
            .error("Something went wrong - partial text may remain in the target app")
        )
        await expectHistoryCount(history, 1)
        let record = try #require(history.records.first)
        #expect(pasteboard.writes.isEmpty)
        #expect(record.output == nil)
        #expect(record.outcome == .failed(
            message: "Something went wrong - partial text may remain in the target app"
        ))
        #expect(typist.cancelCount == 1)
        #expect(metrics.deliveryModes == [.streamedPartial])
    }

    @Test
    func preDeltaProviderErrorReportsPlainFailureWithoutPartialTextWarning() async throws {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let feedback = SpyFeedback()
        let metrics = SpyPipelineMetrics()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                deltas: [],
                terminalError: .transformer
            ),
            pasteboard: pasteboard,
            feedback: feedback,
            metrics: metrics,
            history: history,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Something went wrong"))
        await expectHistoryCount(history, 1)
        let record = try #require(history.records.first)
        #expect(pasteboard.writes.isEmpty)
        #expect(record.outcome == .failed(message: "Something went wrong"))
        #expect(typist.hasPostedText == false)
        #expect(typist.cancelCount == 1)
        #expect(metrics.deliveryModes.isEmpty)
    }

    @Test
    func bufferedButUntypedStreamErrorReportsPlainFailure() async throws {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let typist = SpyStreamingTypist()
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let metrics = SpyPipelineMetrics()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(
                deltas: ["Held back"],
                terminalError: .transformer
            ),
            pasteboard: pasteboard,
            metrics: metrics,
            history: history,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Something went wrong"))
        await expectHistoryCount(history, 1)
        let record = try #require(history.records.first)
        #expect(typist.appendedDeltas == ["Held back"])
        #expect(typist.hasPostedText == false)
        #expect(pasteboard.writes.isEmpty)
        #expect(record.outcome == .failed(message: "Something went wrong"))
        #expect(metrics.deliveryModes.isEmpty)
    }

    @Test
    func cancelSynchronouslyStopsPendingStreamingCadence() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let streamPair = AsyncThrowingStream<String, any Error>.makeStream()
        let sleeper = ManualResetSleeper()
        var postedChunks: [TypingStep] = []
        let typist = StreamingTypist(
            cadence: .milliseconds(50),
            sizeThreshold: 200,
            trustStatus: { true },
            secureInputStatus: { false },
            frontmostApplicationID: { "app-a" },
            eventPoster: { text in
                postedChunks.append(text)
                return true
            },
            sleeper: { _ in
                try await sleeper.sleep(nanoseconds: 0)
            }
        )
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(stream: streamPair.stream),
            pasteboard: pasteboard,
            history: history,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()
        streamPair.continuation.yield("abcdef")
        await sleeper.waitForCallCount(1)

        state.cancelRequested()
        await sleeper.waitForCancellationCount(1)
        await sleeper.resumeCall(0, throwing: CancellationError())
        streamPair.continuation.finish()
        await state.waitForPendingWork()

        #expect(state.pipelineState == .idle)
        #expect(postedChunks.isEmpty)
        #expect(typist.hasPostedText == false)
        #expect(pasteboard.writes.isEmpty)
        #expect(history.records.isEmpty)
    }

    @Test
    func cancelMidStreamLeavesTypedPrefixButNoClipboardOrHistory() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        let streamPair = AsyncThrowingStream<String, any Error>.makeStream()
        let typist = SpyStreamingTypist()
        typist.postsTextOnAppend = true
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let state = makeState(
            settings: settings,
            transformer: FakeStreamingTextTransformer(stream: streamPair.stream),
            pasteboard: pasteboard,
            history: history,
            streamingTypistFactory: { typist }
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectStreamingTypistStartCount(typist, 1)
        await withCheckedContinuation { continuation in
            typist.onTextPosted = { continuation.resume() }
            streamPair.continuation.yield("Typed prefix")
        }

        state.cancelRequested()
        streamPair.continuation.finish()
        await expectState(state, .idle)

        #expect(typist.appendedDeltas == ["Typed prefix"])
        #expect(pasteboard.writes.isEmpty)
        #expect(history.records.isEmpty)
    }

    @Test
    func twoBackToBackSuccessfulRunsWriteDistinctResultsAndReturnToIdle() async {
        let transcriber = QueuedTranscriber([
            "  primeiro texto  ",
            "  segundo texto  ",
        ])
        let transformer = QueuedTextTransformer([
            "First text",
            "Second text",
        ])
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transcriber: transcriber,
            transformer: transformer,
            pasteboard: pasteboard
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["First text"])
        #expect(state.pipelineState == .idle)

        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["First text", "Second text"])
        #expect(state.pipelineState == .idle)
        #expect(state.lastResult == "Second text")

        let receivedTexts = await transformer.receivedTexts
        #expect(receivedTexts == ["primeiro texto", "segundo texto"])
    }
}
