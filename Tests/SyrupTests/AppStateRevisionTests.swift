import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// Revising the last result.
@MainActor
struct AppStateRevisionTests {
    @Test
    func startRevisionWithoutSuccessfulHistoryIsNoop() {
        let recorder = FakeRecorder()
        let state = makeState(recorder: recorder)

        #expect(state.revisionMenuActionTitle == "Revise last result")
        #expect(state.canPerformRevisionMenuAction == false)

        state.performRevisionMenuAction()
        state.startRevision()

        #expect(state.pipelineState == .idle)
        #expect(recorder.startCallCount == 0)
    }

    @Test
    func startRevisionIsRefusedWhileAnyRunIsActive() async {
        let dictation = ActiveRunTraits(isRevision: false, hotkeyMode: .hold, triggerWorkflowID: nil, deliveryCommitted: false)
        for activeState in [AppState.PipelineState.recording, .transcribing, .translating] {
            for event in [PipelineEvent.revisionPressed, .revisionMenu] {
                #expect(PipelineTransitions.command(
                    for: event, in: activeState, run: dictation, hasLastResult: true
                ) == .ignore)
            }
        }

        let recorder = FakeRecorder()
        let history = HistoryStore()
        history.append(successfulRecord(output: "Original result"))
        let state = makeState(recorder: recorder, history: history)
        state.triggerPressed()
        await eventually { recorder.startCallCount == 1 }

        state.startRevision()

        #expect(state.pipelineState == .recording)
        #expect(recorder.startCallCount == 1)
        #expect(state.canPerformRevisionMenuAction == false)
    }

    @Test
    func successfulRevisionBecomesTheBaseForTheNextRevision() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        settings.addGlossaryTerm(GlossaryTerm(term: "Syrup", mishearings: ["sirup"]))
        let history = HistoryStore()
        history.append(successfulRecord(output: "Original result"))
        let transcriber = QueuedTranscriber(["shorter", "warmer"])
        let transformer = QueuedTextTransformer(["Short result", "Warm short result"])
        let pasteboard = SpyPasteboard()
        let archive = SpyRecordingArchive()
        let state = makeState(
            settings: settings,
            transcriber: transcriber,
            transformer: transformer,
            pasteboard: pasteboard,
            history: history,
            recordingArchive: archive
        )

        state.startRevision()
        state.revisionTriggerReleased()
        await expectPasteboardWrites(pasteboard, ["Short result"])

        state.startRevision()
        state.revisionTriggerReleased()
        await expectPasteboardWrites(pasteboard, ["Short result", "Warm short result"])

        #expect(state.lastResult == "Warm short result")
        let vocabularies = await transcriber.vocabularies
        let expectedVocabulary = AppSettings.composedSpeechVocabulary(
            glossary: settings.glossaryList,
            includeCommonTechTerms: settings.includeCommonTechTerms
        )
        #expect(vocabularies == [expectedVocabulary, expectedVocabulary])
        let receivedTexts = await transformer.receivedTexts
        #expect(receivedTexts == ["Original result", "Short result"])
        let newestRecord = try #require(history.records.first)
        let expectedInstruction = PromptBuilder.compose(
            base: PromptBuilder.revisionInstruction(adjustment: "warmer"),
            glossary: PromptBuilder.glossaryBlock(for: settings.glossaryList),
            context: nil,
            contract: PromptBuilder.outputContract
        )
        #expect(newestRecord.transcript == "warmer")
        #expect(newestRecord.transformation == .revision(
            adjustment: "warmer",
            instruction: expectedInstruction
        ))
        // Recordings are filed after delivery, each run on its own task, so wait for them and don't
        // depend on which of the two finished first.
        await state.waitForPendingWork()
        let archiveSnapshot = await archive.snapshot()
        #expect(archiveSnapshot.begunEntryIDs.count == 2)
        #expect(archiveSnapshot.commits.map(\.appleTranscript).sorted() == ["shorter", "warmer"])
        #expect(archiveSnapshot.discardedEntryIDs.isEmpty)
    }

    @Test
    func menuRevisionActionStartsAndFinishesRevision() async {
        let history = HistoryStore()
        history.append(successfulRecord(output: "Original result"))
        let transcriber = FakeTranscriber(.suspended)
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transcriber: transcriber,
            transformer: FakeTextTransformer(.success("Revised result")),
            pasteboard: pasteboard,
            history: history
        )

        #expect(state.revisionMenuActionTitle == "Revise last result")
        #expect(state.canPerformRevisionMenuAction)

        state.performRevisionMenuAction()
        await transcriber.waitForCall()

        #expect(state.pipelineState == .recording)
        #expect(state.revisionMenuActionTitle == "Finish revision")
        #expect(state.canPerformRevisionMenuAction)

        state.performRevisionMenuAction()
        await expectState(state, .transcribing)

        #expect(state.revisionMenuActionTitle == "Revise last result")
        #expect(state.canPerformRevisionMenuAction == false)

        await transcriber.succeed("shorter")
        await expectPasteboardWrites(pasteboard, ["Revised result"])

        #expect(state.lastResult == "Revised result")
        #expect(state.revisionMenuActionTitle == "Revise last result")
        #expect(state.canPerformRevisionMenuAction)
    }

    @Test
    func dictationReleaseDoesNotStopRevisionRecording() async {
        let recorder = FakeRecorder()
        let history = HistoryStore()
        history.append(successfulRecord(output: "Original result"))
        let pasteboard = SpyPasteboard()
        let state = makeState(
            recorder: recorder,
            transcriber: FakeTranscriber(.success("shorter")),
            transformer: FakeTextTransformer(.success("Revised result")),
            pasteboard: pasteboard,
            history: history
        )

        state.startRevision()
        await expectRecorderStartCount(recorder, 1)

        state.triggerReleased()
        await Task.yield()

        #expect(state.pipelineState == .recording)
        #expect(pasteboard.writes.isEmpty)

        state.revisionTriggerReleased()
        await expectPasteboardWrites(pasteboard, ["Revised result"])
    }

    @Test
    func cancelMidRevisionLeavesPreviousResultAndClipboardUntouched() async {
        let history = HistoryStore()
        history.append(successfulRecord(output: "Original result"))
        let transformer = FakeTextTransformer(.suspended)
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transcriber: FakeTranscriber(.success("shorter")),
            transformer: transformer,
            pasteboard: pasteboard,
            history: history
        )

        state.startRevision()
        state.revisionTriggerReleased()
        await transformer.waitForCall()

        state.cancelRequested()
        await expectState(state, .idle)

        #expect(state.lastResult == "Original result")
        #expect(history.records.count == 1)
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func failedRevisionLeavesPreviousResultAndClipboardUntouched() async throws {
        let history = HistoryStore()
        history.append(successfulRecord(output: "Original result"))
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transcriber: FakeTranscriber(.success("shorter")),
            transformer: StaticErrorTextTransformer(error: TranslationError.rateLimited),
            pasteboard: pasteboard,
            history: history
        )

        state.startRevision()
        state.revisionTriggerReleased()
        await expectState(state, .error("Rate limited"))

        #expect(state.lastResult == "Original result")
        #expect(pasteboard.writes.isEmpty)
        #expect(state.transcriptFallback == nil)
        let failedRecord = try #require(history.records.first)
        #expect(failedRecord.transcript == "shorter")
        #expect(failedRecord.output == "Original result")
        #expect(failedRecord.outcome == .failed(message: "Rate limited"))
    }

    @Test
    func failedRevisionPreservesLastResultAfterHistoryEvictsOriginalSuccess() async throws {
        let history = HistoryStore(capacity: 4)
        history.append(successfulRecord(output: "Original result"))
        let excludedTransformations: [DictationRecord.TransformationSnapshot] = [
            .translation(targetLanguage: "English", toneInstruction: ""),
            .custom(workflowName: "Polish", instruction: "Polish this."),
            .contextual(workflowName: "Reply Draft", instruction: "Draft a reply."),
        ]
        for transformation in excludedTransformations {
            history.append(DictationRecord(
                id: UUID(),
                finishedAt: Date.now,
                transcript: "failed input",
                output: "Excluded failed output",
                transformation: transformation,
                outcome: .failed(message: "failed")
            ))
        }

        let pasteboard = SpyPasteboard()
        let failingState = makeState(
            transcriber: FakeTranscriber(.success("shorter")),
            transformer: StaticErrorTextTransformer(error: TranslationError.rateLimited),
            pasteboard: pasteboard,
            history: history
        )

        #expect(failingState.lastResult == "Original result")
        failingState.startRevision()
        failingState.revisionTriggerReleased()
        await expectState(failingState, .error("Rate limited"))

        #expect(history.records.count == 4)
        #expect(history.records.contains(where: { $0.outcome == .success }) == false)
        let failedRevision = try #require(history.records.first)
        let isRevision: Bool
        if case .revision = failedRevision.transformation {
            isRevision = true
        } else {
            isRevision = false
        }
        #expect(isRevision)
        #expect(failedRevision.output == "Original result")
        #expect(failingState.lastResult == "Original result")

        failingState.copyLastResult()
        #expect(pasteboard.writes == ["Original result"])

        let transformer = FakeTextTransformer(.success("Revised preserved base"))
        let succeedingState = makeState(
            transcriber: FakeTranscriber(.success("warmer")),
            transformer: transformer,
            pasteboard: pasteboard,
            history: history
        )

        succeedingState.startRevision()
        succeedingState.revisionTriggerReleased()
        await expectPasteboardWrites(pasteboard, [
            "Original result",
            "Revised preserved base",
        ])

        let receivedText = await transformer.receivedText
        #expect(receivedText == "Original result")
        #expect(succeedingState.lastResult == "Revised preserved base")
    }

    @Test
    func revisionDeliveryCommitsBeforeAutoPasteDelayAndIgnoresPostCommitCancel() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        let history = HistoryStore()
        history.append(successfulRecord(output: "Original result"))
        let pasteboard = SpyPasteboard()
        let autoPaster = SpyAutoPaster()
        let metrics = SpyPipelineMetrics()
        let sleeper = ManualResetSleeper()
        let state = makeState(
            settings: settings,
            transcriber: FakeTranscriber(.success("shorter")),
            transformer: FakeTextTransformer(.success("Revised result")),
            pasteboard: pasteboard,
            metrics: metrics,
            history: history,
            autoPaster: autoPaster,
            autoPasteDelayNanoseconds: 1_000_000_000,
            autoPasteSleeper: { nanoseconds in
                try await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )

        state.startRevision()
        state.revisionTriggerReleased()
        await sleeper.waitForCallCount(1)

        #expect(state.pipelineState == .translating)
        #expect(pasteboard.writes == ["Revised result"])
        #expect(history.records.count == 2)
        #expect(history.records.first?.output == "Revised result")
        #expect(state.lastResult == "Revised result")
        #expect(autoPaster.pasteCount == 0)

        state.cancelRequested()
        await Task.yield()

        #expect(state.pipelineState == .translating)
        #expect(pasteboard.writes == ["Revised result"])
        #expect(history.records.count == 2)
        #expect(autoPaster.pasteCount == 0)

        await sleeper.resumeCall(0)
        await expectAutoPasteCompleted(autoPaster, metrics: metrics)
        await expectState(state, .idle)

        #expect(state.lastResult == "Revised result")
        #expect(autoPaster.pasteCount == 1)
    }

    @Test
    func cancelBeforeRevisionDeliveryCommitSkipsClipboardHistoryAndAutoPasteDelay() async {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        let history = HistoryStore()
        history.append(successfulRecord(output: "Original result"))
        let transformer = FakeTextTransformer(.suspended)
        let pasteboard = SpyPasteboard()
        let autoPaster = SpyAutoPaster()
        let sleeper = ManualResetSleeper()
        let state = makeState(
            settings: settings,
            transcriber: FakeTranscriber(.success("shorter")),
            transformer: transformer,
            pasteboard: pasteboard,
            history: history,
            autoPaster: autoPaster,
            autoPasteDelayNanoseconds: 1_000_000_000,
            autoPasteSleeper: { nanoseconds in
                try await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )

        state.startRevision()
        state.revisionTriggerReleased()
        await transformer.waitForCall()

        state.cancelRequested()
        await expectState(state, .idle)
        await state.waitForPendingWork()

        let autoPasteDelayCallCount = await sleeper.observedCallCount()
        #expect(autoPasteDelayCallCount == 0)
        #expect(state.lastResult == "Original result")
        #expect(history.records.count == 1)
        #expect(pasteboard.writes.isEmpty)
        #expect(autoPaster.pasteCount == 0)
    }
}
