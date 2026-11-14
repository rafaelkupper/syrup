import Foundation
import Testing
@testable import Syrup

struct PipelineTransitionsTests {
    private let hold = ActiveRunTraits(isRevision: false, hotkeyMode: .hold, triggerWorkflowID: nil, deliveryCommitted: false)
    private let toggle = ActiveRunTraits(isRevision: false, hotkeyMode: .toggle, triggerWorkflowID: nil, deliveryCommitted: false)
    private let revisionHold = ActiveRunTraits(isRevision: true, hotkeyMode: .hold, triggerWorkflowID: nil, deliveryCommitted: false)

    private func command(_ event: PipelineEvent, _ state: PipelineState, _ run: ActiveRunTraits? = nil,
                         hasLastResult: Bool = true) -> PipelineCommand {
        PipelineTransitions.command(for: event, in: state, run: run, hasLastResult: hasLastResult)
    }

    @Test func pressingStartsFromIdleOrErrorAndCancelsWhileProcessing() {
        let workflow = UUID()
        #expect(command(.triggerPressed(workflowID: workflow), .idle) == .startRun(workflowID: workflow))
        #expect(command(.triggerPressed(workflowID: nil), .error("x")) == .startRun(workflowID: nil))
        #expect(command(.triggerPressed(workflowID: nil), .transcribing, hold) == .cancelRun)
        #expect(command(.triggerPressed(workflowID: nil), .translating, hold) == .cancelRun)
    }

    @Test func holdStopsOnReleaseAndToggleStopsOnTheSecondPressOfTheSameTrigger() {
        let workflow = UUID()
        let toggleWorkflow = ActiveRunTraits(isRevision: false, hotkeyMode: .toggle, triggerWorkflowID: workflow,
                                             deliveryCommitted: false)
        #expect(command(.triggerReleased(workflowID: nil), .recording, hold) == .stopRecording)
        #expect(command(.triggerPressed(workflowID: nil), .recording, hold) == .ignore)
        #expect(command(.triggerPressed(workflowID: nil), .recording, toggle) == .stopRecording)
        #expect(command(.triggerReleased(workflowID: nil), .recording, toggle) == .ignore)
        #expect(command(.triggerPressed(workflowID: nil), .recording, toggleWorkflow) == .ignore)
        #expect(command(.triggerPressed(workflowID: workflow), .recording, toggleWorkflow) == .stopRecording)
    }

    @Test func releaseOutsideRecordingIsAlwaysIgnored() {
        for state in [PipelineState.idle, .transcribing, .translating, .error("x")] {
            #expect(command(.triggerReleased(workflowID: nil), state, hold) == .ignore)
        }
    }

    @Test func dictationTriggersNeverStopARevisionAndRevisionTriggersNeverStopADictation() {
        #expect(command(.triggerReleased(workflowID: nil), .recording, revisionHold) == .ignore)
        #expect(command(.revisionReleased, .recording, revisionHold) == .stopRecording)
        #expect(command(.revisionReleased, .recording, hold) == .ignore)
        #expect(command(.revisionMenu, .recording, revisionHold) == .stopRecording)
        #expect(command(.revisionMenu, .recording, hold) == .ignore)
    }

    @Test func revisionStartsOnlyWithAResultAndOnlyWhenNothingRuns() {
        #expect(command(.revisionPressed, .idle) == .startRevision)
        #expect(command(.revisionPressed, .idle, hasLastResult: false) == .ignore)
        #expect(command(.revisionMenu, .error("x")) == .startRevision)
        for state in [PipelineState.transcribing, .translating] {
            #expect(command(.revisionPressed, state, revisionHold) == .ignore)
            #expect(command(.revisionMenu, state, revisionHold) == .ignore)
        }
    }

    @Test func aTriggerPressAfterDeliveryIsCommittedLeavesTheRunToFinish() {
        let committed = ActiveRunTraits(isRevision: false, hotkeyMode: .hold, triggerWorkflowID: nil, deliveryCommitted: true)
        for state in [PipelineState.transcribing, .translating] {
            #expect(command(.triggerPressed(workflowID: nil), state, committed) == .ignore)
            #expect(command(.triggerPressed(workflowID: UUID()), state, committed) == .ignore)
        }
    }

    @Test func cancelEndsAnyRunUntilDeliveryIsCommitted() {
        let committed = ActiveRunTraits(isRevision: false, hotkeyMode: .hold, triggerWorkflowID: nil, deliveryCommitted: true)
        #expect(command(.cancel, .idle) == .ignore)
        #expect(command(.cancel, .error("x")) == .cancelRun)
        #expect(command(.cancel, .recording, hold) == .cancelRun)
        #expect(command(.cancel, .translating, committed) == .ignore)
    }
}

@MainActor
@Suite(.serialized)
struct PipelineRunTests {
    private let suite = testDomainName("SyrupPipelineRunTests")

    private func settings() throws -> (AppSettings, UserDefaults) {
        let defaults = try #require(TestDefaults(suiteName: suite))
        return (AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" }), defaults)
    }

    private func settle(_ state: AppState) async {
        await settleRun(state)
    }

    @Test func clipboardRecoveryDeliversTheFittedTextAndKeepsTheExactResultInHistory() async throws {
        let (settings, defaults) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.matchesSentenceAtCaret = true
        let context = CaretContext(precedingWordCharacter: true, continuesSentence: true, textFollows: true)
        let output = "Então vamos."
        let fitted = SentenceFit.apply(output, context: context, protectedTerms: [])
        #expect(fitted != output)
        let clipboard = FailingOncePasteboard()
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("fixture")),
            transformer: FakeTextTransformer(.success(output)), pasteboard: clipboard, feedback: SpyFeedback(),
            autoPaster: SpyAutoPaster(isTrusted: true), maximumRecordingDurationNanoseconds: 0,
            recordingClock: FastForwardClock(), frontmostApplication: { _ in ("fixture", 1) },
            captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }, contextProbe: { context }) }
        )

        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await settle(state)
        #expect(state.pipelineState == .error("Clipboard could not be written"))
        #expect(state.canCopyPendingResult)

        state.copyPendingResult()

        #expect(clipboard.writes == [fitted])
        #expect(state.history.records.first?.output == output)
        #expect(state.lastResult == output)
    }

    @Test func aFailureBeforeTransformationNeverOffersAnOlderRecordsActions() async throws {
        let (settings, defaults) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let error = TranslationError.missingConfiguration("fixture")
        let history = HistoryStore()
        history.append(DictationRecord(
            id: UUID(), finishedAt: .now, transcript: "older dictation", output: nil,
            transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: .failed(message: userMessage(for: error)), provider: .openAICompatible
        ))
        let feedback = SpyFeedback()
        let state = AppState.fixture(
            settings: settings, history: history, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("fixture")),
            transformerProvider: StaticTransformerProvider(transformer: FailedTextTransformer(error: error)),
            pasteboard: SpyPasteboard(), feedback: feedback, autoPaster: SpyAutoPaster(),
            maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock()
        )

        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await settle(state)

        #expect(state.pipelineState == .error(userMessage(for: error)))
        #expect(feedback.transformationFailures.isEmpty)
        #expect(feedback.errorMessages == [userMessage(for: error)])
    }

    @Test func aTransformationFailureOffersThisRunsRecord() async throws {
        let (settings, defaults) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let feedback = SpyFeedback()
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("fixture")),
            transformer: FakeTextTransformer(.failure(.transformer)), pasteboard: SpyPasteboard(),
            feedback: feedback, autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0,
            recordingClock: FastForwardClock()
        )

        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await settle(state)

        let record = try #require(state.history.records.first)
        #expect(feedback.transformationFailures.map(\.recordID) == [record.id])
    }

    @Test func theMicrophoneOpensBeforeASlowSelectionReadFinishes() async throws {
        let (settings, defaults) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.includeSelectionContext = true }
        let recorder = FakeRecorder()
        let reader = SuspendedSelectionReader()
        let clipboard = SpyPasteboard()
        let state = AppState.fixture(
            settings: settings, audioRecorder: recorder, transcriber: FakeTranscriber(.success("fixture")),
            transformer: FakeTextTransformer(.success("Done")), pasteboard: clipboard, feedback: SpyFeedback(),
            autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0,
            recordingClock: FastForwardClock(), selectionReader: reader
        )

        state.triggerPressed()
        await eventually("The selection read never started") { reader.isWaiting }
        await eventually("The recorder waited for the selection read") { recorder.startCallCount == 1 }

        reader.resume(with: .text("selected context"))
        state.triggerReleased()
        await settle(state)

        #expect(state.pipelineState == .idle)
        #expect(clipboard.writes == ["Done"])
    }

    @Test func aTriggerPressDuringTheAutoPasteDelayLetsTheCommittedRunFinish() async throws {
        let (settings, defaults) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.autoPasteEnabled = true
        settings.playSounds = true
        let sleeper = ManualResetSleeper()
        let clipboard = SpyPasteboard()
        let paster = SpyAutoPaster(isTrusted: true)
        let feedback = SpyFeedback()
        let recorder = FakeRecorder()
        let state = AppState.fixture(
            settings: settings, audioRecorder: recorder, transcriber: FakeTranscriber(.success("fixture")),
            transformer: FakeTextTransformer(.success("Done")), pasteboard: clipboard, feedback: feedback,
            autoPaster: paster, maximumRecordingDurationNanoseconds: 0,
            autoPasteSleeper: { try await sleeper.sleep(nanoseconds: $0) }, recordingClock: FastForwardClock(),
            frontmostApplication: { _ in ("fixture", 1) },
            captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) }
        )

        state.triggerPressed()
        await Task.yield()
        state.triggerReleased()
        await eventually("The run never reached the auto-paste delay") { await sleeper.observedCallCount() == 1 }
        #expect(clipboard.writes == ["Done"])
        #expect(state.pipelineState.acceptsNewRun == false)

        state.triggerPressed()
        state.triggerReleased()
        await sleeper.resumeCall(0)
        await settle(state)

        #expect(paster.pasteCount == 1)
        #expect(feedback.successSoundCount == 1)
        #expect(state.pipelineState == .idle)
        #expect(recorder.startCallCount == 1)
    }

    @Test func spokenEditSettingsAreReadAtTheTriggerNotAfterTheSelectionRead() async throws {
        let (settings, defaults) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.translationProvider = .openAICompatible
        settings.handlesSelfCorrections = true
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.includeSelectionContext = true }
        let reader = SuspendedSelectionReader()
        let transformer = FakeTextTransformer(.success("Done"))
        let state = AppState.fixture(
            settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("fixture")),
            transformer: transformer, pasteboard: SpyPasteboard(), feedback: SpyFeedback(),
            autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0,
            recordingClock: FastForwardClock(), selectionReader: reader
        )

        state.triggerPressed()
        await eventually("The selection read never started") { reader.isWaiting }
        settings.handlesSelfCorrections = false
        reader.resume(with: .text("selected context"))
        state.triggerReleased()
        await settle(state)

        let instruction = try #require(await transformer.receivedInstruction)
        #expect(instruction.contains(PromptBuilder.selfCorrectionInstruction))
    }

    @Test func quittingEndsTheActiveRun() async throws {
        let (settings, defaults) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = FakeRecorder()
        let clipboard = SpyPasteboard()
        let state = AppState.fixture(
            settings: settings, audioRecorder: recorder, transcriber: FakeTranscriber(.suspended),
            transformer: FakeTextTransformer(.success("never")), pasteboard: clipboard, feedback: SpyFeedback(),
            autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock()
        )
        state.triggerPressed()
        await eventually { recorder.startCallCount == 1 }

        await state.prepareForTermination()

        #expect(state.pipelineState == .idle)
        #expect(recorder.stopCallCount >= 1)
        #expect(clipboard.writes.isEmpty)
    }
}

@MainActor
private final class FailingOncePasteboard: PasteboardWriting {
    private(set) var writes: [String] = []
    private var failsNext = true

    func write(_ string: String) throws {
        if failsNext {
            failsNext = false
            throw ClipboardError.writeFailed
        }
        writes.append(string)
    }
}

@MainActor
private final class SuspendedSelectionReader: SelectionReading {
    private var continuation: CheckedContinuation<RunSelectionCapture, Never>?
    var isWaiting: Bool { continuation != nil }

    func captureForRun(processID: pid_t?) async -> RunSelectionCapture {
        await withCheckedContinuation { continuation = $0 }
    }

    func resume(with selection: SelectionCapture) {
        continuation?.resume(returning: RunSelectionCapture(selection: selection))
        continuation = nil
    }
}
