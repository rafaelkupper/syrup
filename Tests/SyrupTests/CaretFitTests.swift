import Foundation
import Synchronization
import Testing
@testable import Syrup

struct SentenceFitTests {
    @Test(arguments: [
        ("Então vamos", "então vamos"), ("Hello there.", "hello there"),
        ("Pedro disse", "Pedro disse"), ("I think", "I think"),
        ("I'm here.", "I'm here"), ("I’m here.", "I’m here"), ("Let's go.", "let's go"),
        ("API", "API"), ("APIs", "APIs"), ("iPhone", "iPhone"),
        ("Version2 works.", "Version2 works"), ("Kubernetes works.", "Kubernetes works"),
        ("\"Hello there.\"", "\"hello there.\""), ("(Hello there.)", "(hello there.)"),
        ("Hello...", "hello..."), ("Hello..", "hello.."), ("Hello…", "hello…"),
        ("Hello?", "hello?"), ("Hello!", "hello!"),
        ("Keep etc.", "keep etc."), ("Use vs.", "use vs."),
        ("Call Dr.", "call Dr."), ("Call Sr.", "call Sr."), ("Call Sra.", "call Sra."),
        ("Use p.ex.", "use p.ex."), ("Use e.g.", "use e.g."), ("Use U.S.", "use U.S."),
        ("  Hello\nWorld. \n", "  hello\nWorld \n"), ("", ""), (".", "."),
        ("[Então vamos]", "[então vamos]")
    ])
    func fitsOnlyFirstLetterAndOnePeriod(input: String, expected: String) {
        #expect(SentenceFit.apply(input, context: CaretContext(continuesSentence: true, textFollows: true),
                                 protectedTerms: ["Kubernetes"]) == expected)
    }

    @Test(arguments: [false, true])
    func noSentenceContinuationLeavesCaseAlone(textFollows: Bool) {
        #expect(SentenceFit.apply("Hello world.", context: CaretContext(textFollows: textFollows),
                                 protectedTerms: []) == (textFollows ? "Hello world" : "Hello world."))
    }

    @Test func caseSensitiveGlossaryAndNames() {
        let context = CaretContext(continuesSentence: true)
        #expect(SentenceFit.apply("Quuxwidget works", context: context, protectedTerms: ["Quuxwidget"]) == "Quuxwidget works")
        #expect(SentenceFit.apply("Quuxwidget works", context: context, protectedTerms: ["quuxwidget"]) == "quuxwidget works")
        #expect(SentenceFit.apply("Pedro disse", context: context, protectedTerms: []) == "Pedro disse")
        #expect(SentenceFit.apply("London is busy", context: context, protectedTerms: []) == "London is busy")
        #expect(SentenceFit.apply("Microsoft builds software", context: context, protectedTerms: []) == "Microsoft builds software")
    }

    @Test(arguments: [
        ("e ", "depois", false, true, true, false),
        ("word", " next", true, true, true, false),
        ("word", " next", false, true, true, true),
        ("", "", false, false, false, false),
        ("word\n \t", "\nnext", false, false, false, false),
        ("done. \t", "\tnext", false, false, true, false),
        ("done!\" ", "?", false, false, false, false),
        ("done?) ", " ", false, false, false, false),
        ("done… ", " next", false, false, true, false),
        ("label: ", "\t7", false, false, true, false),
        ("word, ", "next", false, true, true, false),
        ("word;\t", " next", false, true, true, false),
        ("7", "_next", false, true, false, true),
        ("é", "next", false, true, true, true),
        ("e\u{301}", "next", false, true, true, false),
        ("🙂", "next", false, false, true, false),
        ("_", "next", false, false, true, true)
    ])
    func parsesBoundedContext(before: String, after: String, selection: Bool, continues: Bool, follows: Bool, spacing: Bool) {
        let context = CaretContext.parse(before: before, after: after, hasSelection: selection)
        #expect(context == CaretContext(precedingWordCharacter: spacing, continuesSentence: continues, textFollows: follows))
    }
}

@MainActor
struct CaretFitDeliveryTests {
    @Test(arguments: [PasteStrategy.commandV(9), .typeText])
    func fittedClipboardKeepsExactHistory(strategy: PasteStrategy) async {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        fixture.settings.smartSpacingEnabled = true
        fixture.paster.strategy = strategy
        let state = fixture.state(output: "Então vamos.")
        await fixture.run(state)
        #expect(fixture.clipboard.writes == ["então vamos"])
        #expect(state.history.records.first?.output == "Então vamos.")
        #expect(fixture.typist.appendedDeltas == (strategy == .typeText ? [" então vamos"] : [" "]))
        #expect(fixture.paster.pasteCount == (strategy == .typeText ? 0 : 1))
        #expect(fixture.reads.value.withLock { $0 } == 1)
    }

    @Test(arguments: [true, false])
    func unchangedTextUsesCommandV(enabled: Bool) async {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        fixture.settings.matchesSentenceAtCaret = enabled
        let state = fixture.state(output: enabled ? "API" : "Então vamos.")
        await fixture.run(state)
        #expect(fixture.paster.pasteCount == 1)
        #expect(fixture.typist.appendedDeltas.isEmpty)
        #expect(fixture.reads.value.withLock { $0 } == (enabled ? 1 : 0))
    }

    @Test(arguments: [true, false])
    func pasteLastFitsAgainFromTheExactHistory(autoPaste: Bool) async {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        let state = fixture.state(output: "Então vamos.")
        await fixture.run(state)
        fixture.settings.autoPasteEnabled = autoPaste
        await state.pasteLastResult()
        // With automatic paste off, Paste Last copies the exact result and reads nothing.
        #expect(fixture.clipboard.writes == ["então vamos", autoPaste ? "então vamos" : "Então vamos."])
        #expect(fixture.typist.appendedDeltas.isEmpty)
        #expect(fixture.paster.pasteCount == (autoPaste ? 2 : 1))
        #expect(state.history.records.count == 1)
        #expect(state.history.records.first?.output == "Então vamos.")
        #expect(fixture.reads.value.withLock { $0 } == (autoPaste ? 2 : 1))
    }

    @Test func automaticPasteOffStillFitsTheClipboard() async {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        fixture.settings.autoPasteEnabled = false
        let state = fixture.state(output: "Então vamos.")
        await fixture.run(state)
        #expect(fixture.clipboard.writes == ["então vamos"])
        #expect(state.history.records.first?.output == "Então vamos.")
        #expect(fixture.paster.pasteCount == 0)
        #expect(fixture.typist.appendedDeltas.isEmpty)
        #expect(fixture.reads.value.withLock { $0 } == 1)
    }

    @Test func withoutAccessibilityTheClipboardKeepsTheExactResult() async {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        fixture.settings.autoPasteEnabled = false
        fixture.paster.isTrusted = false
        await fixture.run(fixture.state(output: "Então vamos."))
        #expect(fixture.clipboard.writes == ["Então vamos."])
        #expect(fixture.reads.value.withLock { $0 } == 0)
    }

    @Test(arguments: [true, false])
    func onboardingTasteHoldsTheFit(holdsPaste: Bool) {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        fixture.settings.autoPasteEnabled = false
        let run = PipelineRun(configuration: fixture.settings.runConfiguration(workflowID: nil), triggerWorkflowID: nil,
                              triggeredAt: ContinuousClock.now, settings: fixture.settings, holdsPaste: holdsPaste,
                              activities: SpyProcessActivity())
        #expect(run.matchesSentenceAtCaret == !holdsPaste)
        run.endActivity()
    }

    @Test func unavailableContextLeavesDeliveryUntouched() async {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        fixture.context = nil
        await fixture.run(fixture.state(output: "Hello world."))
        #expect(fixture.paster.pasteCount == 1)
        #expect(fixture.typist.appendedDeltas.isEmpty)
    }

    @Test func failedTypingKeepsTheFittedCopyAndReportsFailure() async {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        fixture.paster.strategy = .typeText
        fixture.typist.stopAfterFirstAppend = .eventCreationFailed
        await fixture.run(fixture.state(output: "Então vamos."))
        #expect(fixture.clipboard.writes == ["então vamos"])
        #expect(fixture.typist.appendedDeltas == ["então vamos"])
        #expect(fixture.paster.pasteCount == 0)
        #expect(fixture.feedback.errorMessages == ["Typing stopped - the full result was copied."])
    }

    @Test func preferenceIsRawDefaultOffAndCapturedAtTrigger() async {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        let reloaded = AppSettings(userDefaults: fixture.defaults, defaultMicrophoneIDProvider: { "" })
        #expect(reloaded.matchesSentenceAtCaret)
        fixture.settings.matchesSentenceAtCaret = false
        #expect(fixture.defaults.object(forKey: "matchesSentenceAtCaret") as? Bool == false)
        fixture.settings.matchesSentenceAtCaret = true
        let state = fixture.state(output: "Então vamos.")
        state.triggerPressed()
        fixture.settings.matchesSentenceAtCaret = false
        await Task.yield()
        state.triggerReleased()
        await fixture.settle(state)
        #expect(fixture.clipboard.writes == ["então vamos"])
        #expect(fixture.paster.pasteCount == 1)
        #expect(fixture.typist.appendedDeltas.isEmpty)
    }

    @Test(arguments: [true, false])
    func streamingClipboardMatchesTheTypedText(autoPaste: Bool) async {
        let fixture = CaretFitFixture()
        defer { fixture.clean() }
        fixture.settings.autoPasteEnabled = autoPaste
        fixture.settings.streamingDeliveryEnabled = true
        fixture.settings.smartSpacingEnabled = true
        var steps: [TypingStep] = []
        let typist = StreamingTypist(sizeThreshold: 1, trustStatus: { true }, secureInputStatus: { false },
            frontmostApplicationID: { "fixture" }, eventPoster: { steps.append($0); return true },
            sleeper: { _ in try await Task.sleep(for: .seconds(60)) })
        let state = fixture.state(output: "Então vamos.", streaming: true, realTypist: typist)
        await fixture.run(state)
        #expect(steps == (autoPaste ? [.text(" então "), .text("vamos")] : []))
        #expect(fixture.clipboard.writes == ["então vamos"])
        #expect(state.history.records.first?.output == "Então vamos.")
        #expect(fixture.reads.value.withLock { $0 } == 1)
        #expect(fixture.paster.pasteCount == 0)
    }

    @Test func contextTimeoutAndChangedTargetFallBack() async {
        let gate = ManualResetSleeper()
        let target = DeliveryTarget(checkCurrent: { true }, contextProbe: {
            try? await gate.sleep(nanoseconds: 0)
            return CaretContext(continuesSentence: true)
        })
        #expect(await target.caretContext(readsSentence: true) == nil)
        await gate.resumeAll(throwing: CancellationError())
        let changed = DeliveryTarget(checkCurrent: { false }, contextProbe: { CaretContext(continuesSentence: true) })
        #expect(await changed.caretContext(readsSentence: true) == nil)
    }
}

@MainActor
private final class CaretFitFixture {
    let suite = testDomainName("CaretFit")
    let defaults: UserDefaults
    let settings: AppSettings
    let clipboard = SpyPasteboard()
    let typist = SpyStreamingTypist()
    let paster = SpyAutoPaster()
    let feedback = SpyFeedback()
    let reads = CaretFitProbeCounter()
    var context: CaretContext? = CaretContext(precedingWordCharacter: true, continuesSentence: true, textFollows: true)

    init() {
        defaults = TestDefaults(suiteName: suite)!
        settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        #expect(!settings.matchesSentenceAtCaret)
        settings.matchesSentenceAtCaret = true
        settings.autoPasteEnabled = true
        settings.pinDeliveryTarget = false
    }

    func clean() { defaults.removePersistentDomain(forName: suite) }

    func state(output: String, streaming: Bool = false, realTypist: (any StreamingTyping)? = nil) -> AppState {
        let context = context, reads = reads
        let transformer: any TextTransformer = streaming
            ? FakeStreamingTextTransformer(atomicOutput: output, deltas: ["En", "tão ", "vamos."])
            : FakeTextTransformer(.success(output))
        return AppState.fixture(settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("fixture")),
            transformer: transformer, pasteboard: clipboard, feedback: feedback, autoPaster: paster,
            streamingTypistFactory: { realTypist ?? self.typist }, maximumRecordingDurationNanoseconds: 0,
            autoPasteDelayNanoseconds: 0, recordingClock: FastForwardClock(),
            frontmostApplication: { _ in ("fixture", 1) },
            captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }, contextProbe: {
                reads.value.withLock { $0 += 1 }; return context
            }) })
    }

    func run(_ state: AppState) async {
        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await settle(state)
    }

    func settle(_ state: AppState) async {
        await settleRun(state)
    }
}

@MainActor
struct CaretFitStreamingTests {
    @Test(arguments: [1, 200])
    func waitsForCompleteFirstWordAndDropsFinalPeriod(threshold: Int) async throws {
        var text = ""
        let typist = makeTypist(threshold: threshold) { text += $0 }
        try typist.start()
        typist.addLeadingSpace()
        typist.setSentenceFit(context: CaretContext(continuesSentence: true, textFollows: true), protectedTerms: [])
        typist.append("En")
        await typist.waitForQueuedFlushes()
        #expect(text.isEmpty)
        typist.append("tão")
        await typist.waitForQueuedFlushes()
        #expect(text.isEmpty)
        typist.append(" vamos.")
        await typist.waitForQueuedFlushes()
        await typist.finish()
        #expect(text == " então vamos")
    }

    @Test(arguments: [1, 200])
    func preservesNamesAndAbbreviationsAcrossDeltas(threshold: Int) async throws {
        var text = ""
        let typist = makeTypist(threshold: threshold) { text += $0 }
        try typist.start()
        typist.setSentenceFit(context: CaretContext(continuesSentence: true, textFollows: true), protectedTerms: [])
        for delta in ["Pe", "dro ", "disse ", "p.", "ex", "."] { typist.append(delta) }
        await typist.finish()
        #expect(text == "Pedro disse p.ex.")
    }

    @Test(arguments: [true, false])
    func protectsGlossaryPhrasesAcrossDeltas(matchesTerm: Bool) async throws {
        var text = ""
        let typist = makeTypist(threshold: 1) { text += $0 }
        try typist.start()
        typist.setSentenceFit(context: CaretContext(continuesSentence: true), protectedTerms: ["Example Product"])
        typist.append("Example ")
        await typist.waitForQueuedFlushes()
        #expect(text.isEmpty)
        typist.append("Pro")
        await typist.waitForQueuedFlushes()
        #expect(text.isEmpty)
        typist.append(matchesTerm ? "duct works." : "ject works.")
        await typist.waitForQueuedFlushes()
        await typist.finish()
        #expect(text == (matchesTerm ? "Example Product works." : "example Project works."))
    }

    @Test(arguments: ["Hello.", "Hello...", "Hello?", "Hello!", "  \"Hello.\"  "])
    func finishOnlyUsesSameFit(input: String) async throws {
        var text = ""
        let typist = makeTypist(threshold: 200) { text += $0 }
        try typist.start()
        typist.addLeadingSpace()
        let context = CaretContext(continuesSentence: true, textFollows: true)
        typist.setSentenceFit(context: context, protectedTerms: [])
        typist.append(input)
        await typist.waitForQueuedFlushes()
        await typist.finish()
        #expect(text == " " + SentenceFit.apply(ModelOutputNormalizer.normalize(input), context: context, protectedTerms: []))
    }

    private func makeTypist(threshold: Int, post: @escaping (String) -> Void) -> StreamingTypist {
        StreamingTypist(sizeThreshold: threshold, trustStatus: { true }, secureInputStatus: { false },
            frontmostApplicationID: { "fixture" }, eventPoster: { step in
                switch step { case .text(let text): post(text); case .lineBreak: post("\n") }
                return true
            }, sleeper: { _ in try await Task.sleep(for: .seconds(60)) })
    }
}

private final class CaretFitProbeCounter: Sendable {
    let value = Mutex(0)
}
