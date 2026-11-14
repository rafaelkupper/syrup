import AVFoundation
import Foundation
import Testing
@testable import Syrup

@MainActor
struct AppStateTests {
    @Test
    func cancelShortcutIsOnlyAvailableDuringActivePipelineStates() {
        #expect(AppState.PipelineState.idle.allowsCancelShortcut == false)
        #expect(AppState.PipelineState.recording.allowsCancelShortcut)
        #expect(AppState.PipelineState.transcribing.allowsCancelShortcut)
        #expect(AppState.PipelineState.translating.allowsCancelShortcut)
        #expect(AppState.PipelineState.error("Boom").allowsCancelShortcut == false)
    }

    @Test
    func menuBarSymbolTracksPipelineState() {
        #expect(AppState.menuBarSymbol(for: .idle, showingSuccess: false) == "waveform")
        #expect(AppState.menuBarSymbol(for: .idle, showingSuccess: true) == "checkmark.circle")
        #expect(AppState.menuBarSymbol(for: .recording, showingSuccess: true) == "waveform.badge.microphone")
        #expect(AppState.menuBarSymbol(for: .transcribing, showingSuccess: false) == "ellipsis")
        #expect(AppState.menuBarSymbol(for: .translating, showingSuccess: false) == "ellipsis")
        #expect(AppState.menuBarSymbol(for: .error("Nope"), showingSuccess: false) == "exclamationmark.triangle")

        let state = makeState()
        #expect(state.menuBarSymbol == "waveform")
        state.triggerPressed()
        #expect(state.menuBarSymbol == "waveform.badge.microphone")
    }

    @Test
    func pausedHotkeyIgnoresTriggerPresses() {
        let recorder = FakeRecorder()
        let state = makeState(recorder: recorder)

        state.isHotkeyPaused = true
        state.triggerPressed()
        state.triggerReleased()

        #expect(state.pipelineState == .idle)
        #expect(recorder.startCallCount == 0)
    }

    @Test
    func learningEnabledArchivesSuccessfulVoiceRun() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            pasteboard: pasteboard,
            recordingArchive: archive
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        await eventually { await archive.snapshot().commits.count == 1 }
        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        let commit = try #require(snapshot.commits.first)
        #expect(snapshot.begunEntryIDs.count == 1)
        #expect(commit.id == begunID)
        #expect(commit.localeID == AppSettings.defaultDictationLocaleID)
        #expect(commit.appleTranscript == "bom dia, tudo bem?")
        #expect(snapshot.discardedEntryIDs.isEmpty)
    }

    @Test
    func cancelledLearningRunDiscardsRecording() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let transcriber = FakeTranscriber(.suspended)
        let state = makeState(
            settings: settings,
            transcriber: transcriber,
            recordingArchive: archive
        )

        state.triggerPressed()
        await transcriber.waitForCall()
        state.cancelRequested()
        await expectState(state, .idle)
        await expectArchiveDiscardCount(archive, 1)

        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs == [begunID])
    }

    @Test
    func archiveFinalizationDoesNotDelayDeliveryAndHonorsOptOut() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let recorder = FakeRecorder()
        recorder.finishesStreamOnStop = false
        let archive = SpyRecordingArchive()
        let pasteboard = SpyPasteboard()
        let transcriber = FakeTranscriber(.success("bom dia"))
        let state = makeState(settings: settings, recorder: recorder, transcriber: transcriber,
                              pasteboard: pasteboard, recordingArchive: archive)
        state.triggerPressed()
        await transcriber.waitForCall()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])
        await expectState(state, .idle)
        #expect(await archive.snapshot().commits.isEmpty)

        settings.glossaryLearningEnabled = false
        recorder.finishesStreamOnStop = true
        recorder.stop()
        await expectArchiveDiscardCount(archive, 1)
        #expect(await archive.snapshot().commits.isEmpty)
    }

    @Test
    func learningDisabledNeverTouchesArchive() async {
        let settings = makeTestSettings()
        let archive = SpyRecordingArchive()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            pasteboard: pasteboard,
            recordingArchive: archive
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        let snapshot = await archive.snapshot()
        #expect(snapshot.begunEntryIDs.isEmpty)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs.isEmpty)
    }

    @Test
    func failedLearningRunNeverPublishesRecording() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let state = makeState(
            settings: settings,
            transformer: FakeTextTransformer(.failure(.transformer)),
            recordingArchive: archive
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectState(state, .error("Something went wrong"))
        await expectArchiveDiscardCount(archive, 1)

        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs == [begunID])
    }

    @Test
    func emptyTranscriptLearningRunLeavesNoRecording() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let state = makeState(
            settings: settings,
            transcriber: FakeTranscriber(.success("  \n")),
            recordingArchive: archive
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectState(state, .error("Nothing heard"))
        await expectArchiveDiscardCount(archive, 1)

        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs == [begunID])
    }

    @Test
    func disablingLearningDuringActiveRunPreventsCommit() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let transcriber = FakeTranscriber(.suspended)
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            transcriber: transcriber,
            pasteboard: pasteboard,
            recordingArchive: archive
        )

        state.triggerPressed()
        await transcriber.waitForCall()
        settings.glossaryLearningEnabled = false
        await applyGlossaryLearningRetentionChange(
            isEnabled: false,
            settings: settings,
            recordingArchive: archive,
            revertsSettingOnFailure: true
        )
        state.triggerReleased()
        await transcriber.succeed("bom dia, tudo bem?")
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        await expectArchiveDiscardCount(archive, 1)
        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs == [begunID])
        #expect(snapshot.deleteAllCount == 1)
    }

    @Test
    func pausingDuringRecordingCancelsWithoutWritingClipboard() async {
        let recorder = FakeRecorder()
        let pasteboard = SpyPasteboard()
        let state = makeState(recorder: recorder, pasteboard: pasteboard)

        state.triggerPressed()
        await expectRecorderStartCount(recorder, 1)

        state.isHotkeyPaused = true
        await expectState(state, .idle)

        #expect(recorder.stopCallCount == 1)
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func idleReleaseAndCancelAreNoops() {
        let recorder = FakeRecorder()
        let state = makeState(recorder: recorder)

        state.triggerReleased()
        state.cancelRequested()

        #expect(state.pipelineState == .idle)
        #expect(recorder.startCallCount == 0)
        #expect(recorder.stopCallCount == 0)
    }

    @Test
    func holdModeStartsTranscribingBeforeRelease() async {
        let transcriber = FakeTranscriber(.suspended)
        let state = makeState(transcriber: transcriber)

        state.triggerPressed()
        await transcriber.waitForCall()
        #expect(state.pipelineState == .recording)

        state.triggerReleased()
        await expectState(state, .transcribing)
    }

    @Test
    func toggleModeStartsTranscribingBeforeSecondPressAndReleaseIsNoop() async {
        let settings = makeTestSettings()
        settings.hotkeyMode = .toggle
        let transcriber = FakeTranscriber(.suspended)
        let state = makeState(settings: settings, transcriber: transcriber)

        state.triggerPressed()
        await transcriber.waitForCall()
        #expect(state.pipelineState == .recording)

        state.triggerReleased()
        #expect(state.pipelineState == .recording)

        state.triggerPressed()
        await expectState(state, .transcribing)

        state.triggerReleased()
        #expect(state.pipelineState == .transcribing)
    }

    @Test
    func recordingDurationLimitStopsRecordingAndCompletesPipeline() async {
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(.success("  bom dia  "))
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let sleeper = ManualResetSleeper()
        let state = makeState(
            recorder: recorder,
            transcriber: transcriber,
            pasteboard: pasteboard,
            feedback: feedback,
            maximumRecordingDurationNanoseconds: 1_000_000_000,
            recordingDurationSleeper: { nanoseconds in
                try await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )

        state.triggerPressed()
        await transcriber.waitForCall()
        await sleeper.waitForCallCount(1)
        #expect(state.pipelineState == .recording)

        await sleeper.resumeCall(0)

        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])
        #expect(recorder.stopCallCount == 1)
        #expect(state.pipelineState == .idle)
        #expect(feedback.autoStoppedDurations == [1])
    }

    @Test
    func cancelDuringRecordingCancelsRecordingDurationLimit() async {
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(.suspended)
        let pasteboard = SpyPasteboard()
        let sleeper = ManualResetSleeper()
        let state = makeState(
            recorder: recorder,
            transcriber: transcriber,
            pasteboard: pasteboard,
            maximumRecordingDurationNanoseconds: 1_000_000_000,
            recordingDurationSleeper: { nanoseconds in
                try await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )

        state.triggerPressed()
        await transcriber.waitForCall()
        await sleeper.waitForCallCount(1)

        state.cancelRequested()

        await expectState(state, .idle)
        await sleeper.waitForCancellationCount(1)
        #expect(recorder.stopCallCount == 1)
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func cancelBeforeRecordingStartsDoesNotStartRecorderOrWriteClipboard() async {
        let recorder = FakeRecorder()
        let pasteboard = SpyPasteboard()
        let state = makeState(recorder: recorder, pasteboard: pasteboard)

        state.triggerPressed()
        state.cancelRequested()
        await Task.yield()

        #expect(state.pipelineState == .idle)
        #expect(recorder.startCallCount == 0)
        #expect(recorder.stopCallCount == 1)
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func cancelDuringActiveRecordingStopsRecorderAndDoesNotWriteClipboard() async {
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(.suspended)
        let pasteboard = SpyPasteboard()
        let state = makeState(
            recorder: recorder,
            transcriber: transcriber,
            pasteboard: pasteboard
        )

        state.triggerPressed()
        await expectRecorderStartCount(recorder, 1)
        await transcriber.waitForCall()
        #expect(state.pipelineState == .recording)

        state.cancelRequested()
        await expectState(state, .idle)

        let transcriberCallCount = await transcriber.callCount
        #expect(recorder.stopCallCount == 1)
        #expect(transcriberCallCount == 1)
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func cancelDuringTranscribingDoesNotWriteClipboard() async {
        let transcriber = FakeTranscriber(.suspended)
        let pasteboard = SpyPasteboard()
        let state = makeState(transcriber: transcriber, pasteboard: pasteboard)

        state.triggerPressed()
        state.triggerReleased()
        await transcriber.waitForCall()
        await expectState(state, .transcribing)

        state.cancelRequested()
        await expectState(state, .idle)
        await transcriber.waitForCancellation()
        await Task.yield()

        #expect(pasteboard.writes.isEmpty)
        #expect(state.canCopyTranscriptFallback == false)
        let cancellationCount = await transcriber.cancellationCount
        #expect(cancellationCount == 1)
    }

    @Test
    func cancelDuringTranslatingDoesNotWriteClipboard() async {
        let transformer = FakeTextTransformer(.suspended)
        let pasteboard = SpyPasteboard()
        let state = makeState(transformer: transformer, pasteboard: pasteboard)

        state.triggerPressed()
        state.triggerReleased()
        await transformer.waitForCall()
        await expectState(state, .translating)

        state.cancelRequested()
        await expectState(state, .idle)
        await Task.yield()

        #expect(pasteboard.writes.isEmpty)
        #expect(state.canCopyTranscriptFallback == false)
    }

    @Test
    func releaseDuringTranslatingIsNoop() async {
        let transformer = FakeTextTransformer(.suspended)
        let state = makeState(transformer: transformer)

        state.triggerPressed()
        state.triggerReleased()
        await transformer.waitForCall()
        await expectState(state, .translating)

        state.triggerReleased()

        #expect(state.pipelineState == .translating)
    }

    @Test
    func recorderFailureMovesToErrorAndDoesNotWriteClipboard() async {
        let recorder = FakeRecorder()
        recorder.startError = FakeFailure.recorder
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(recorder: recorder, pasteboard: pasteboard, feedback: feedback)

        state.triggerPressed()

        await expectState(state, .error("Something went wrong"))
        #expect(pasteboard.writes.isEmpty)
        #expect(feedback.errorMessages == ["Something went wrong"])
    }

    @Test
    func microphonePermissionFailureMovesToSpecificErrorAndDoesNotWriteClipboard() async {
        let recorder = FakeRecorder()
        recorder.startError = AudioRecordingError.microphoneAccessDenied
        let pasteboard = SpyPasteboard()
        let state = makeState(recorder: recorder, pasteboard: pasteboard)

        state.triggerPressed()

        await expectState(
            state,
            .error("Microphone access denied - enable Syrup in System Settings > Privacy & Security > Microphone.")
        )
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func speechPermissionFailureMovesToSpecificErrorAndDoesNotWriteClipboard() async {
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transcriber: FakeTranscriber(.failure(.speechPermission)),
            pasteboard: pasteboard
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(
            state,
            .error("Speech recognition access denied - enable Syrup in System Settings > Privacy & Security > Speech Recognition.")
        )
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func languageModelDownloadInProgressMovesToSpecificErrorAndDoesNotWriteClipboard() async {
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transcriber: FakeTranscriber(.failure(.languageModelInstalling)),
            pasteboard: pasteboard
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(
            state,
            .error("Portuguese (Brazil) language model is downloading - open Settings to see progress.")
        )
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func transcriberFailureMovesToErrorAndDoesNotWriteClipboard() async {
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transcriber: FakeTranscriber(.failure(.transcriber)),
            pasteboard: pasteboard
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Something went wrong"))
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func transformerFailureMovesToErrorAndDoesNotWriteClipboard() async {
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transformer: FakeTextTransformer(.failure(.transformer)),
            pasteboard: pasteboard
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Something went wrong"))
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func translationFailureOffersExplicitTranscriptFallback() async {
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(
            transcriber: FakeTranscriber(.success("  bom dia  ")),
            transformer: StaticErrorTextTransformer(error: TranslationError.rateLimited),
            pasteboard: pasteboard,
            feedback: feedback
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Rate limited"))
        #expect(pasteboard.writes.isEmpty)
        #expect(state.canCopyTranscriptFallback)
        #expect(feedback.transformationFailures.map(\.message) == ["Rate limited"])

        state.copyTranscriptFallback()

        await expectState(state, .idle)
        #expect(pasteboard.writes == ["bom dia"])
        #expect(state.lastResult == "bom dia")
        #expect(state.canCopyTranscriptFallback == false)
        #expect(feedback.successSoundCount == 1)
    }

    @Test
    func unreachableEndpointShowsMappedErrorAndPreservesTranscriptFallback() async {
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(
            transcriber: FakeTranscriber(.success("bom dia")),
            transformer: StaticErrorTextTransformer(error: TranslationError.cannotConnect("localhost")),
            pasteboard: pasteboard,
            feedback: feedback
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Can't reach localhost"))
        #expect(pasteboard.writes.isEmpty)
        #expect(state.canCopyTranscriptFallback)
        #expect(feedback.transformationFailures.map(\.message) == ["Can't reach localhost"])
    }

    @Test
    func timedOutTranslationShowsMappedErrorAndPreservesTranscriptFallback() async {
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(
            transcriber: FakeTranscriber(.success("bom dia")),
            transformer: StaticErrorTextTransformer(error: TranslationError.timedOut),
            pasteboard: pasteboard,
            feedback: feedback
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Translation timed out"))
        #expect(pasteboard.writes.isEmpty)
        #expect(state.canCopyTranscriptFallback)
        #expect(feedback.transformationFailures.map(\.message) == ["Translation timed out"])
    }

    @Test
    func revisionAndContextualFailuresNeverExposeTranscriptFallback() {
        let history = HistoryStore()
        let state = makeState(history: history)
        history.append(DictationRecord(
            id: UUID(),
            finishedAt: .now,
            transcript: "shorter",
            output: nil,
            transformation: .revision(
                adjustment: "shorter",
                instruction: "Revise the text."
            ),
            outcome: .failed(message: "failed")
        ))

        #expect(state.transcriptFallback == nil)

        history.append(DictationRecord(
            id: UUID(),
            finishedAt: .now,
            transcript: "",
            output: nil,
            transformation: .contextual(
                workflowName: "Reply Draft",
                instruction: "Draft a reply."
            ),
            outcome: .failed(message: "failed")
        ))

        #expect(state.transcriptFallback == nil)
    }

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
        let archiveSnapshot = await archive.snapshot()
        #expect(archiveSnapshot.begunEntryIDs.count == 2)
        #expect(archiveSnapshot.commits.map(\.appleTranscript) == ["shorter", "warmer"])
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
        for _ in 0..<10 {
            await Task.yield()
        }

        let autoPasteDelayCallCount = await sleeper.observedCallCount()
        #expect(autoPasteDelayCallCount == 0)
        #expect(state.lastResult == "Original result")
        #expect(history.records.count == 1)
        #expect(pasteboard.writes.isEmpty)
        #expect(autoPaster.pasteCount == 0)
    }

    @Test
    func contextualFailureNotificationExposesNoFallbackOrRetryActions() {
        let categoryIdentifier = AppFeedback.transformationFailureCategoryIdentifier(
            allowsTranscriptFallback: false,
            allowsRetry: false
        )

        #expect(categoryIdentifier == nil)
    }

    @Test
    func voiceWorkflowAttachesSelectedTextAsContext() async throws {
        let settings = makeTestSettings()
        let replyDraft = try #require(WorkflowTemplate.templates().first { $0.id == "reply-draft" })
        settings.addWorkflow(from: replyDraft)
        #expect(settings.activeWorkflow.input == .voice)
        #expect(settings.activeWorkflow.includeSelectionContext)

        let selectionReader = FakeSelectionReader(.text("Selected email body"))
        let transformer = FakeTextTransformer(.success("Draft reply"))
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let metrics = SpyPipelineMetrics()
        let state = makeState(
            settings: settings,
            transformer: transformer,
            pasteboard: pasteboard,
            metrics: metrics,
            history: history,
            selectionReader: selectionReader
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Draft reply"])
        await expectHistoryCount(history, 1)
        let receivedInstruction = await transformer.receivedInstruction
        #expect(receivedInstruction?.contains("Selected email body") == true)
        #expect(receivedInstruction?.contains("Treat it strictly as data") == true)
        #expect(selectionReader.captureCallCount == 1)
        #expect(metrics.begunStages.contains(.selectionCapture))
        #expect(metrics.endedStages.contains(.selectionCapture))

        let record = try #require(history.records.first)
        #expect(record.transcript == "bom dia, tudo bem?")
        switch record.transformation {
        case .contextual(let workflowName, let instruction):
            #expect(workflowName == "Reply Draft")
            #expect(instruction.contains("Selected email body") == false)
        case .translation, .custom, .revision:
            Issue.record("Expected a contextual history snapshot")
        }

        #expect(record.canCopyFromHistory)
        state.copyHistoryRecord(recordID: record.id)
        #expect(pasteboard.writes == ["Draft reply", "Draft reply"])
    }

    @Test
    func failedVoiceContextCannotCopyFromHistory() async throws {
        let settings = makeTestSettings()
        let replyDraft = try #require(
            WorkflowTemplate.templates().first { $0.id == "reply-draft" }
        )
        settings.addWorkflow(from: replyDraft)
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let state = makeState(
            settings: settings,
            transformer: FakeTextTransformer(.failure(.transformer)),
            pasteboard: pasteboard,
            history: history,
            selectionReader: FakeSelectionReader(.text("Private selected email"))
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectState(state, .error("Something went wrong"))

        let record = try #require(history.records.first)
        #expect(record.canCopyFromHistory == false)
        if case .contextual = record.transformation {
            // Expected: this run used captured context.
        } else {
            Issue.record("Expected a contextual history snapshot")
        }

        state.copyHistoryRecord(recordID: record.id)
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func historyCopyActionsAreIgnoredWhileRunIsActive() throws {
        let history = HistoryStore()
        let failedRecord = DictationRecord(
            id: UUID(),
            finishedAt: .now,
            transcript: "bom dia",
            output: nil,
            transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: .failed(message: "Rate limited")
        )
        history.append(failedRecord)
        let pasteboard = SpyPasteboard()
        let state = makeState(pasteboard: pasteboard, history: history)

        state.triggerPressed()
        #expect(state.pipelineState == .recording)
        #expect(state.canCopyTranscriptFallback == false)

        state.copyHistoryRecord(recordID: failedRecord.id)
        state.copyTranscriptFallback()

        #expect(pasteboard.writes.isEmpty)
        #expect(state.pipelineState == .recording)

        state.cancelRequested()
        #expect(state.pipelineState == .idle)
        #expect(state.canCopyTranscriptFallback)
    }

    @Test
    func voiceWorkflowProceedsWithoutEmptyContextAndNotifiesOnce() async throws {
        let settings = makeTestSettings()
        let replyDraft = try #require(WorkflowTemplate.templates().first { $0.id == "reply-draft" })
        settings.addWorkflow(from: replyDraft)
        let selectionReader = FakeSelectionReader(.empty)
        let transformer = FakeTextTransformer(.success("Draft reply"))
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let history = HistoryStore()
        let state = makeState(
            settings: settings,
            transformer: transformer,
            pasteboard: pasteboard,
            feedback: feedback,
            history: history,
            selectionReader: selectionReader
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectHistoryCount(history, 1)
        await expectState(state, .idle)

        state.triggerPressed()
        state.triggerReleased()
        await expectHistoryCount(history, 2)
        await expectState(state, .idle)

        #expect(pasteboard.writes == ["Draft reply", "Draft reply"])
        #expect(feedback.errorMessages == ["No selected text — ran without context"])
        #expect(selectionReader.captureCallCount == 2)
        let receivedInstruction = await transformer.receivedInstruction
        #expect(receivedInstruction?.contains("Context —") == false)
    }

    @Test
    func failedVoiceWorkflowWithEmptyContextKeepsRetryAndFallback() async throws {
        try await verifyFailedVoiceContextMiss(
            capture: .empty,
            expectedNotification: "No selected text — ran without context"
        )
    }

    @Test
    func failedVoiceWorkflowWithoutAccessibilityKeepsRetryAndFallback() async throws {
        try await verifyFailedVoiceContextMiss(
            capture: .notTrusted,
            expectedNotification: "No selected text — grant Accessibility to attach context"
        )
    }

    @Test
    func selectionInputSkipsRecordingAndTranscription() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let summarizeSelection = try #require(
            WorkflowTemplate.templates().first { $0.id == "summarize-selection" }
        )
        let translateSelection = try #require(
            WorkflowTemplate.templates().first { $0.id == "translate-selection" }
        )
        settings.addWorkflow(from: summarizeSelection)
        #expect(settings.activeWorkflow.name == "Summarize Selection")
        #expect(settings.activeWorkflow.input == .selection)
        #expect(translateSelection.input == .selection)

        let selectionReader = FakeSelectionReader(.text("Selected paragraph"))
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(.success("must not be used"))
        let transformer = FakeTextTransformer(.success("- Summary"))
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let metrics = SpyPipelineMetrics()
        let archive = SpyRecordingArchive()
        let state = makeState(
            settings: settings,
            recorder: recorder,
            transcriber: transcriber,
            transformer: transformer,
            pasteboard: pasteboard,
            metrics: metrics,
            history: history,
            selectionReader: selectionReader,
            recordingArchive: archive
        )

        state.triggerPressed()

        await expectPasteboardWrites(pasteboard, ["- Summary"])
        await expectHistoryCount(history, 1)
        let transcriberCallCount = await transcriber.callCount
        let receivedText = await transformer.receivedText
        let receivedInstruction = await transformer.receivedInstruction
        #expect(recorder.startCallCount == 0)
        #expect(transcriberCallCount == 0)
        #expect(receivedText == "Selected paragraph")
        #expect(receivedInstruction?.contains("Selected paragraph") == false)
        #expect(metrics.begunStages.contains(.selectionCapture))
        #expect(metrics.begunStages.contains(.hotkeyToRecordingStarted) == false)
        let archiveSnapshot = await archive.snapshot()
        #expect(archiveSnapshot.begunEntryIDs.isEmpty)
        #expect(archiveSnapshot.commits.isEmpty)
        #expect(archiveSnapshot.discardedEntryIDs.isEmpty)

        let record = try #require(history.records.first)
        #expect(record.transcript.isEmpty)
        #expect(record.output == "- Summary")
        if case .contextual = record.transformation {
            // Expected: the selected input is never persisted in the snapshot.
        } else {
            Issue.record("Expected a contextual history snapshot")
        }
    }

    @Test
    func selectionInputFailsFastWhenNothingIsSelected() async throws {
        let settings = makeTestSettings()
        let summarizeSelection = try #require(
            WorkflowTemplate.templates().first { $0.id == "summarize-selection" }
        )
        settings.addWorkflow(from: summarizeSelection)
        let selectionReader = FakeSelectionReader(.empty)
        let recorder = FakeRecorder()
        let transcriber = FakeTranscriber(.success("must not be used"))
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(
            settings: settings,
            recorder: recorder,
            transcriber: transcriber,
            pasteboard: pasteboard,
            feedback: feedback,
            selectionReader: selectionReader
        )

        state.triggerPressed()

        let transcriberCallCount = await transcriber.callCount
        #expect(state.pipelineState == .error("No text selected"))
        #expect(recorder.startCallCount == 0)
        #expect(transcriberCallCount == 0)
        #expect(pasteboard.writes.isEmpty)
        #expect(feedback.errorMessages == ["No text selected"])
    }

    @Test
    func selectionInputWithoutAccessibilityPromptsForTrustOncePerSession() async throws {
        let settings = makeTestSettings()
        let summarizeSelection = try #require(
            WorkflowTemplate.templates().first { $0.id == "summarize-selection" }
        )
        settings.addWorkflow(from: summarizeSelection)
        let autoPaster = SpyAutoPaster(isTrusted: false)
        let state = makeState(
            settings: settings,
            autoPaster: autoPaster,
            selectionReader: FakeSelectionReader(.notTrusted)
        )

        state.triggerPressed()
        await expectState(state, .error(
            "Accessibility access required - grant Syrup access in System Settings > Privacy & Security > Accessibility."
        ))
        #expect(autoPaster.requestTrustCount == 1)

        state.triggerPressed()
        #expect(autoPaster.requestTrustCount == 1)
    }

    @Test
    func selectionInputIgnoresHoldAndToggleReleaseSemantics() async throws {
        let summarizeSelection = try #require(
            WorkflowTemplate.templates().first { $0.id == "summarize-selection" }
        )

        for mode in [HotkeyMode.hold, .toggle] {
            let settings = makeTestSettings()
            settings.hotkeyMode = mode
            settings.addWorkflow(from: summarizeSelection)
            let transformer = FakeTextTransformer(.suspended)
            let state = makeState(
                settings: settings,
                transformer: transformer,
                selectionReader: FakeSelectionReader(.text("Selected paragraph"))
            )

            state.triggerPressed()
            await transformer.waitForCall()
            #expect(state.pipelineState == .translating)

            state.triggerReleased()
            #expect(state.pipelineState == .translating)

            state.cancelRequested()
            await transformer.waitForCancellation()
            #expect(state.pipelineState == .idle)
        }
    }

    @Test
    func cancelingSelectionInputDoesNotWriteClipboardOrHistory() async throws {
        let settings = makeTestSettings()
        let summarizeSelection = try #require(
            WorkflowTemplate.templates().first { $0.id == "summarize-selection" }
        )
        settings.addWorkflow(from: summarizeSelection)
        let transformer = FakeTextTransformer(.suspended)
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let state = makeState(
            settings: settings,
            transformer: transformer,
            pasteboard: pasteboard,
            history: history,
            selectionReader: FakeSelectionReader(.text("Selected paragraph"))
        )

        state.triggerPressed()
        await transformer.waitForCall()
        #expect(state.pipelineState == .translating)

        state.cancelRequested()
        await transformer.waitForCancellation()

        #expect(state.pipelineState == .idle)
        #expect(pasteboard.writes.isEmpty)
        #expect(history.records.isEmpty)
    }

    @Test
    func failedSelectionInputStoresNoSelectionAndOffersNoFallbackOrRetry() async throws {
        let settings = makeTestSettings()
        let summarizeSelection = try #require(
            WorkflowTemplate.templates().first { $0.id == "summarize-selection" }
        )
        settings.addWorkflow(from: summarizeSelection)
        let transformer = FakeTextTransformer(.failure(.transformer))
        let pasteboard = SpyPasteboard()
        let history = HistoryStore()
        let feedback = SpyFeedback()
        let state = makeState(
            settings: settings,
            transformer: transformer,
            pasteboard: pasteboard,
            feedback: feedback,
            history: history,
            selectionReader: FakeSelectionReader(.text("Private selected paragraph"))
        )

        state.triggerPressed()
        await expectState(state, .error("Something went wrong"))

        let record = try #require(history.records.first)
        #expect(record.transcript.isEmpty)
        #expect(record.output == nil)
        #expect(record.canUseTranscriptFallback == false)
        #expect(record.canRetry == false)
        #expect(record.canCopyFromHistory == false)
        #expect(state.transcriptFallback == nil)
        #expect(feedback.transformationFailures.map(\.allowsTranscriptFallback) == [false])
        #expect(feedback.transformationFailures.map(\.allowsRetry) == [false])

        state.retryTranslation(recordID: record.id)
        let transformerCallCount = await transformer.callCount
        #expect(transformerCallCount == 1)

        state.copyHistoryRecord(recordID: record.id)
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func clipboardFailureMovesToErrorAndDoesNotMarkSuccess() async {
        let pasteboard = FailingPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(pasteboard: pasteboard, feedback: feedback)

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Clipboard could not be written"))
        #expect(state.lastResult == nil)
        #expect(feedback.errorMessages == ["Clipboard could not be written"])
    }

    @Test
    func transcriptFallbackCopyFailureKeepsFallbackAvailable() async {
        let pasteboard = FailingPasteboard()
        let state = makeState(
            transcriber: FakeTranscriber(.success("bom dia")),
            transformer: StaticErrorTextTransformer(error: TranslationError.rateLimited),
            pasteboard: pasteboard
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectState(state, .error("Rate limited"))

        state.copyTranscriptFallback()

        await expectState(state, .error("Clipboard could not be written"))
        #expect(state.canCopyTranscriptFallback)
        #expect(state.lastResult == nil)
    }

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
    func transformationFailureAppendsFailedHistoryRecord() async throws {
        let history = HistoryStore()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transformer: StaticErrorTextTransformer(error: TranslationError.rateLimited),
            pasteboard: pasteboard,
            history: history
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Rate limited"))
        await expectHistoryCount(history, 1)
        let record = try #require(history.records.first)
        #expect(record.transcript == "bom dia, tudo bem?")
        #expect(record.output == nil)
        #expect(record.outcome == .failed(message: "Rate limited"))
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
        let state = makeState(pasteboard: clipboard, feedback: feedback, history: history,
                              autoPaster: paster, streamingTypistFactory: { typist })
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

    @Test func pasteLastDelayCannotPostIntoANewRun() async {
        let history = HistoryStore()
        history.append(successfulRecord(output: "previous"))
        let clipboard = SpyPasteboard(), paster = SpyAutoPaster()
        let sleeper = ManualResetSleeper()
        let state = makeState(transcriber: FakeTranscriber(.suspended), pasteboard: clipboard,
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
        await Task.yield()

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
    func retryTranslationUsesFailedRecordSnapshotCurrentGlossaryAndRecordedProvider() async {
        let settings = makeTestSettings()
        settings.translationProvider = .openAICompatible
        settings.handlesSelfCorrections = true
        settings.handlesSpokenFormatting = true
        settings.addGlossaryTerm(GlossaryTerm(
            term: "Syrup",
            mishearings: ["sirup"]
        ))
        let failedRecord = DictationRecord(
            id: UUID(),
            finishedAt: Date.now,
            transcript: "bom dia",
            output: nil,
            transformation: .translation(targetLanguage: "German", toneInstruction: "Use a concise tone."),
            outcome: .failed(message: "Rate limited"),
            provider: .appleOnDevice
        )
        let history = HistoryStore()
        history.append(failedRecord)
        let pasteboard = SpyPasteboard()
        let transformer = FakeTextTransformer(.success("Guten Morgen"))
        let state = makeState(
            settings: settings,
            transformer: transformer,
            pasteboard: pasteboard,
            history: history
        )

        state.retryTranslation(recordID: failedRecord.id)

        await expectPasteboardWrites(pasteboard, ["Guten Morgen"])
        await expectHistoryCount(history, 2)
        let receivedInstruction = await transformer.receivedInstruction
        // Both toggles are on, but the recorded provider is Apple On-Device, which never gets spoken edits.
        #expect(receivedInstruction == PromptBuilder.systemPrompt(
            targetLanguage: "German",
            toneInstruction: "Use a concise tone.",
            glossary: settings.glossaryList,
            dictation: .off
        ))
        #expect(history.records.first?.output == "Guten Morgen")
    }

    @Test
    func successfulRunRecordsPrivacySafeLatencyStages() async {
        let transcriber = FakeTranscriber(.success("bom dia, tudo bem?"))
        let metrics = SpyPipelineMetrics()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transcriber: transcriber,
            pasteboard: pasteboard,
            metrics: metrics
        )

        state.triggerPressed()
        await transcriber.waitForCall()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])
        #expect(Set(metrics.begunStages) == Set([
            .hotkeyToRecordingStarted,
            .translationConfiguration,
            .transcriptionWindow,
            .releaseToRecorderStopped,
            .releaseToTranscript,
            .releaseToClipboard,
            .translation,
            .clipboardWrite,
        ]))
        #expect(Set(metrics.endedStages) == Set([
            .hotkeyToRecordingStarted,
            .translationConfiguration,
            .releaseToRecorderStopped,
            .transcriptionWindow,
            .releaseToTranscript,
            .translation,
            .clipboardWrite,
            .releaseToClipboard,
        ]))
        #expect(metrics.begunStages.firstIndex(of: .translationConfiguration)! < metrics.begunStages.firstIndex(of: .releaseToRecorderStopped)!)
        #expect(metrics.begunStages.firstIndex(of: .transcriptionWindow)! < metrics.begunStages.firstIndex(of: .releaseToRecorderStopped)!)
        #expect(metrics.endedStages.firstIndex(of: .releaseToClipboard)! > metrics.endedStages.firstIndex(of: .clipboardWrite)!)
    }

    @Test
    func latencyRegressionGateStartsTranscriptionAndProviderPreparationBeforeRelease() async {
        let transcriber = FakeTranscriber(.suspended)
        let provider = SuspendedTextTransformerProvider(transformer: FakeTextTransformer(.success("Prepared result")))
        let metrics = SpyPipelineMetrics()
        let state = makeState(
            transcriber: transcriber,
            transformerProvider: provider,
            metrics: metrics
        )

        state.triggerPressed()
        await transcriber.waitForCall()
        await provider.waitForCall()

        #expect(state.pipelineState == .recording)
        #expect(metrics.begunStages.contains(.transcriptionWindow))
        #expect(metrics.begunStages.contains(.translationConfiguration))
        #expect(metrics.begunStages.contains(.releaseToRecorderStopped) == false)
        #expect(metrics.begunStages.contains(.releaseToTranscript) == false)
        #expect(metrics.begunStages.contains(.releaseToClipboard) == false)

        state.cancelRequested()
        await provider.resume()
        await expectState(state, .idle)
    }

    @Test
    func transformerProviderResolutionStartsBeforeRelease() async {
        let provider = SuspendedTextTransformerProvider(transformer: FakeTextTransformer(.success("Prepared result")))
        let state = makeState(transformerProvider: provider)

        state.triggerPressed()
        await provider.waitForCall()

        #expect(state.pipelineState == .recording)

        state.cancelRequested()
        await provider.resume()
    }

    @Test
    func cancelDuringPreparedTextTransformerResolutionDoesNotStartTranslationMetrics() async {
        let transformer = FakeTextTransformer(.success("Should not happen"))
        let provider = SuspendedTextTransformerProvider(transformer: transformer)
        let metrics = SpyPipelineMetrics()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transformerProvider: provider,
            pasteboard: pasteboard,
            metrics: metrics
        )

        state.triggerPressed()
        state.triggerReleased()
        await provider.waitForCall()
        await expectState(state, .translating)

        state.cancelRequested()
        await expectState(state, .idle)

        await provider.resume()
        for _ in 0..<20 {
            await Task.yield()
        }

        let transformerCallCount = await transformer.callCount
        #expect(transformerCallCount == 0)
        #expect(pasteboard.writes.isEmpty)
        #expect(metrics.begunStages.contains(.translation) == false)
        #expect(metrics.endedStages.contains(.translation) == false)
        #expect(metrics.discardedRunIDs.count == 1)
    }

    @Test
    func transformationInstructionIsSnapshottedAtRecordingStart() async {
        let settings = makeTestSettings()
        settings.updateWorkflow(id: settings.activeWorkflow.id) { workflow in
            workflow.kind = .translation(
                targetLanguage: "German",
                tonePreset: .custom,
                customToneText: "Use a concise tone."
            )
        }
        let transcriber = FakeTranscriber(.suspended)
        let transformer = FakeTextTransformer(.success("Hallo Welt"))
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            transcriber: transcriber,
            transformer: transformer,
            pasteboard: pasteboard
        )

        state.triggerPressed()
        await transcriber.waitForCall()
        settings.updateWorkflow(id: settings.activeWorkflow.id) { workflow in
            workflow.kind = .translation(
                targetLanguage: "Italian",
                tonePreset: .custom,
                customToneText: "Use a poetic tone."
            )
        }
        await transcriber.succeed("  ola mundo  ")
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Hallo Welt"])
        let receivedInstruction = await transformer.receivedInstruction
        // Spoken edits are opt-in, so a default run sends neither instruction.
        #expect(receivedInstruction == PromptBuilder.systemPrompt(targetLanguage: "German", toneInstruction: "Use a concise tone.", dictation: .off))
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

    @Test
    func providerSelectionUsesCurrentSettingsForEachRun() async throws {
        let settings = makeTestSettings()
        let transcriber = QueuedTranscriber([
            "  primeiro texto  ",
            "  segundo texto  ",
        ])
        let openAITextTransformer = FakeTextTransformer(.success("OpenAI-compatible result"))
        let codexTextTransformer = FakeTextTransformer(.success("Codex CLI result"))
        let pasteboard = SpyPasteboard()
        let (keychainStore, storageDirectory) = temporaryKeychainStore()
        defer {
            try? keychainStore.delete()
            try? FileManager.default.removeItem(at: storageDirectory)
        }
        let state = makeState(
            settings: settings,
            transcriber: transcriber,
            transformerProvider: AppSettingsTransformerProvider(
                settings: settings,
                keychainStore: keychainStore,
                openAICompatibleTransformer: openAITextTransformer,
                codexCLITransformer: codexTextTransformer
            ),
            pasteboard: pasteboard
        )

        settings.translationProvider = .openAICompatible
        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["OpenAI-compatible result"])

        settings.translationProvider = .codexCLI
        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["OpenAI-compatible result", "Codex CLI result"])

        let openAICallCount = await openAITextTransformer.callCount
        let codexCallCount = await codexTextTransformer.callCount
        #expect(openAICallCount == 1)
        #expect(codexCallCount == 1)
    }

    @Test
    func successFeedbackFlashClearsAfterDelay() async {
        let sleeper = ManualResetSleeper()
        let state = makeState(
            feedbackFlashDurationNanoseconds: 1_000_000_000,
            feedbackFlashSleeper: { nanoseconds in
                try await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .idle)
        #expect(state.menuBarSymbol == "checkmark.circle")
        await sleeper.waitForCallCount(1)

        await sleeper.resumeCall(0)

        await expectMenuBarSymbol(state, "waveform")
    }

    @Test
    func successSoundRespectsSettingsToggle() async {
        let settings = makeTestSettings()
        settings.playSounds = false
        let feedback = SpyFeedback()
        let state = makeState(settings: settings, feedback: feedback)

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .idle)
        #expect(feedback.successSoundCount == 0)
        #expect(state.menuBarSymbol == "checkmark.circle")
    }

    @Test
    func copyLastResultRewritesClipboardAndShowsFeedback() async {
        let pasteboard = SpyPasteboard()
        let feedback = SpyFeedback()
        let state = makeState(pasteboard: pasteboard, feedback: feedback)

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        state.copyLastResult()

        #expect(pasteboard.writes == [
            "Good morning, how are you?",
            "Good morning, how are you?",
        ])
        #expect(feedback.successSoundCount == 2)
    }

    @Test
    func failedRunKeepsPreviousLastResultAvailableForRecopy() async {
        let recorder = FakeRecorder()
        let pasteboard = SpyPasteboard()
        let state = makeState(recorder: recorder, pasteboard: pasteboard)

        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        recorder.startError = FakeFailure.recorder
        state.triggerPressed()
        await expectState(state, .error("Something went wrong"))

        #expect(state.lastResult == "Good morning, how are you?")

        state.copyLastResult()

        #expect(pasteboard.writes == [
            "Good morning, how are you?",
            "Good morning, how are you?",
        ])
        #expect(state.pipelineState == .idle)
        #expect(state.menuBarSymbol == "checkmark.circle")
    }

    @Test
    func canceledRunKeepsPreviousLastResultAvailable() async {
        let recorder = FakeRecorder()
        let pasteboard = SpyPasteboard()
        let state = makeState(recorder: recorder, pasteboard: pasteboard)

        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        state.triggerPressed()
        await expectRecorderStartCount(recorder, 2)
        state.cancelRequested()
        await expectState(state, .idle)

        #expect(state.lastResult == "Good morning, how are you?")

        state.copyLastResult()

        #expect(pasteboard.writes == [
            "Good morning, how are you?",
            "Good morning, how are you?",
        ])
    }

    @Test
    func copyingLastResultDuringActiveRunIsNoop() async {
        let recorder = FakeRecorder()
        let pasteboard = SpyPasteboard()
        let state = makeState(recorder: recorder, pasteboard: pasteboard)

        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        state.triggerPressed()
        await expectRecorderStartCount(recorder, 2)
        #expect(state.pipelineState == .recording)
        #expect(state.canCopyLastResult == false)

        state.copyLastResult()

        #expect(pasteboard.writes == ["Good morning, how are you?"])
        #expect(state.pipelineState == .recording)

        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, [
            "Good morning, how are you?",
            "Good morning, how are you?",
        ])
    }

    @Test
    func whitespaceTranscriptShortCircuitsTranslation() async {
        let transformer = FakeTextTransformer(.success("Should not happen"))
        let pasteboard = SpyPasteboard()
        let state = makeState(
            transcriber: FakeTranscriber(.success("  \n\t  ")),
            transformer: transformer,
            pasteboard: pasteboard
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectState(state, .error("Nothing heard"))
        let transformerCallCount = await transformer.callCount
        #expect(transformerCallCount == 0)
        #expect(pasteboard.writes.isEmpty)
    }

    @Test
    func rapidDoublePressInHoldModeDoesNotStartTwoRecordings() async {
        let recorder = FakeRecorder()
        let state = makeState(recorder: recorder)

        state.triggerPressed()
        state.triggerPressed()
        await expectRecorderStartCount(recorder, 1)

        #expect(state.pipelineState == .recording)
        #expect(recorder.startCallCount == 1)
    }

    @Test
    func pressingDuringTranscribingCancels() async {
        let transcriber = FakeTranscriber(.suspended)
        let state = makeState(transcriber: transcriber)

        state.triggerPressed()
        state.triggerReleased()
        await transcriber.waitForCall()
        await expectState(state, .transcribing)

        state.triggerPressed()

        await expectState(state, .idle)
    }

    @Test
    func pressingDuringTranslatingCancels() async {
        let transformer = FakeTextTransformer(.suspended)
        let state = makeState(transformer: transformer)

        state.triggerPressed()
        state.triggerReleased()
        await transformer.waitForCall()
        await expectState(state, .translating)

        state.triggerPressed()

        await expectState(state, .idle)
    }

    @Test
    func pressingFromErrorStartsFreshRecording() {
        let state = stateShowingAnError()
        state.triggerPressed()

        #expect(state.pipelineState == .recording)
    }

    @Test
    func releaseFromErrorIsNoop() {
        let state = stateShowingAnError()
        state.triggerReleased()

        #expect(state.pipelineState == .error("Clipboard could not be written"))
    }

    @Test
    func cancelFromErrorReturnsToIdle() {
        let state = stateShowingAnError()
        state.cancelRequested()

        #expect(state.pipelineState == .idle)
    }

    @Test
    func errorAutoReturnsToIdle() async {
        let recorder = FakeRecorder()
        recorder.startError = FakeFailure.recorder
        let state = makeState(
            recorder: recorder,
            errorResetDelayNanoseconds: 0
        )

        state.triggerPressed()
        await expectRecorderStartCount(recorder, 1)
        await expectState(state, .idle)
    }

    @Test
    func canceledStaleErrorResetDoesNotClearNewError() async {
        let sleeper = ManualResetSleeper()
        let recorder = FakeRecorder()
        recorder.startError = FakeFailure.recorder
        let state = makeState(
            recorder: recorder,
            errorResetDelayNanoseconds: 1_000_000_000,
            errorResetSleeper: { nanoseconds in
                try await sleeper.sleep(nanoseconds: nanoseconds)
            }
        )

        state.triggerPressed()
        await expectState(state, .error("Something went wrong"))
        await sleeper.waitForCallCount(1)

        state.triggerPressed()
        await sleeper.waitForCancellationCount(1)
        await expectRecorderStartCount(recorder, 2)
        await expectState(state, .error("Something went wrong"))
        await sleeper.waitForCallCount(2)

        await sleeper.resumeCall(0, throwing: CancellationError())
        await Task.yield()

        #expect(state.pipelineState == .error("Something went wrong"))

        state.cancelRequested()
        await sleeper.resumeAll(throwing: CancellationError())
    }

    @Test
    func transformationReceivesTrimmedTranscriptAndInstruction() async {
        let settings = makeTestSettings()
        settings.updateWorkflow(id: settings.activeWorkflow.id) { workflow in
            workflow.dictationLocaleID = "pt_BR"
            workflow.kind = .translation(
                targetLanguage: "German",
                tonePreset: .custom,
                customToneText: "Use a concise tone."
            )
        }
        settings.addGlossaryTerm(GlossaryTerm(term: "Syrup", mishearings: ["sirup"]))
        settings.addGlossaryTerm(GlossaryTerm(term: "Zorvex"))
        let transcriber = FakeTranscriber(.success("  ola mundo  "))
        let transformer = FakeTextTransformer(.success("Hallo Welt"))
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            transcriber: transcriber,
            transformer: transformer,
            pasteboard: pasteboard
        )

        state.triggerPressed()
        state.triggerReleased()

        await expectPasteboardWrites(pasteboard, ["Hallo Welt"])
        let localeIdentifier = await transcriber.localeIdentifier
        let vocabulary = await transcriber.vocabulary
        let receivedText = await transformer.receivedText
        let receivedInstruction = await transformer.receivedInstruction
        #expect(localeIdentifier == "pt_BR")
        #expect(vocabulary == AppSettings.composedSpeechVocabulary(
            glossary: settings.glossaryList,
            includeCommonTechTerms: settings.includeCommonTechTerms
        ))
        #expect(receivedText == "ola mundo")
        // Spoken edits are opt-in, so a default run sends neither instruction.
        #expect(receivedInstruction == PromptBuilder.systemPrompt(
            targetLanguage: "German",
            toneInstruction: "Use a concise tone.",
            glossary: settings.glossaryList,
            dictation: .off
        ))
    }
}

@MainActor
private func verifyFailedVoiceContextMiss(
    capture: SelectionCapture,
    expectedNotification: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let settings = makeTestSettings()
    let replyDraft = try #require(
        WorkflowTemplate.templates().first { $0.id == "reply-draft" },
        sourceLocation: sourceLocation
    )
    settings.addWorkflow(from: replyDraft)
    let pasteboard = SpyPasteboard()
    let feedback = SpyFeedback()
    let history = HistoryStore()
    let state = makeState(
        settings: settings,
        transformer: FakeTextTransformer(.failure(.transformer)),
        pasteboard: pasteboard,
        feedback: feedback,
        history: history,
        selectionReader: FakeSelectionReader(capture)
    )

    state.triggerPressed()
    state.triggerReleased()
    await expectState(
        state,
        .error("Something went wrong"),
        sourceLocation: sourceLocation
    )

    let record = try #require(history.records.first, sourceLocation: sourceLocation)
    #expect(record.transformation == .custom(
        workflowName: "Reply Draft",
        instruction: PromptBuilder.instruction(for: replyDraft.kind)
    ), sourceLocation: sourceLocation)
    #expect(record.canUseTranscriptFallback, sourceLocation: sourceLocation)
    #expect(record.canRetry, sourceLocation: sourceLocation)
    #expect(record.canCopyFromHistory, sourceLocation: sourceLocation)
    #expect(
        state.transcriptFallback == "bom dia, tudo bem?",
        sourceLocation: sourceLocation
    )
    #expect(feedback.errorMessages == [expectedNotification], sourceLocation: sourceLocation)
    #expect(
        feedback.transformationFailures.map(\.allowsTranscriptFallback) == [true],
        sourceLocation: sourceLocation
    )
    #expect(
        feedback.transformationFailures.map(\.allowsRetry) == [true],
        sourceLocation: sourceLocation
    )
    #expect(pasteboard.writes.isEmpty, sourceLocation: sourceLocation)
}

@MainActor
private func makeState(
    settings: AppSettings? = nil,
    recorder: FakeRecorder = FakeRecorder(),
    transcriber: any Transcriber = FakeTranscriber(.success("bom dia, tudo bem?")),
    transformer: any TextTransformer = FakeTextTransformer(.success("Good morning, how are you?")),
    transformerProvider: (any TransformerSnapshotting)? = nil,
    pasteboard: any PasteboardWriting = SpyPasteboard(),
    feedback: any AppFeedbackProviding = SpyFeedback(),
    metrics: any PipelineMetricsRecording = PipelineMetricsRecorder(),
    history: HistoryStore = HistoryStore(),
    autoPaster: any AutoPasting = SpyAutoPaster(),
    streamingTypistFactory: @escaping () -> any StreamingTyping = { StreamingTypist() },
    errorResetDelayNanoseconds: UInt64 = 4_000_000_000,
    errorResetSleeper: @escaping ErrorResetSleeper = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    },
    feedbackFlashDurationNanoseconds: UInt64 = 1_000_000_000,
    feedbackFlashSleeper: @escaping FeedbackFlashSleeper = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    },
    maximumRecordingDurationNanoseconds: UInt64? = 0,
    recordingDurationSleeper: @escaping RecordingDurationSleeper = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    },
    autoPasteDelayNanoseconds: UInt64 = 0,
    autoPasteSleeper: @escaping AutoPasteSleeper = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    },
    recordingClock: any RecordingClock = FastForwardClock(),
    installHotkeys: Bool = false,
    selectionReader: any SelectionReading = FakeSelectionReader(.empty),
    recordingArchive: (any RecordingArchiving)? = nil
) -> AppState {
    AppState(
        settings: settings ?? makeTestSettings(),
        history: history,
        audioRecorder: recorder,
        transcriber: transcriber,
        transformer: transformer,
        transformerProvider: transformerProvider,
        pasteboard: pasteboard,
        feedback: feedback,
        metrics: metrics,
        autoPaster: autoPaster,
        streamingTypistFactory: streamingTypistFactory,
        errorResetDelayNanoseconds: errorResetDelayNanoseconds,
        errorResetSleeper: errorResetSleeper,
        feedbackFlashDurationNanoseconds: feedbackFlashDurationNanoseconds,
        feedbackFlashSleeper: feedbackFlashSleeper,
        maximumRecordingDurationNanoseconds: maximumRecordingDurationNanoseconds,
        recordingDurationSleeper: recordingDurationSleeper,
        autoPasteDelayNanoseconds: autoPasteDelayNanoseconds,
        autoPasteSleeper: autoPasteSleeper,
        recordingClock: recordingClock,
        installHotkeys: installHotkeys,
        selectionReader: selectionReader,
        recordingArchive: recordingArchive,
        captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) }
    )
}

private func temporaryKeychainStore() -> (KeychainStore, URL) {
    let storageDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SyrupAppStateTests.\(UUID().uuidString)", isDirectory: true)
    let store = KeychainStore(
        service: "org.syrup.SyrupAppStateTests",
        storageDirectory: storageDirectory
    )
    return (store, storageDirectory)
}

private func successfulRecord(output: String) -> DictationRecord {
    DictationRecord(
        id: UUID(),
        finishedAt: Date.now,
        transcript: "Original dictation",
        output: output,
        transformation: .translation(targetLanguage: "English", toneInstruction: ""),
        outcome: .success
    )
}

/// A real error state: Copy Last fails on a clipboard that refuses writes.
@MainActor
private func stateShowingAnError() -> AppState {
    let history = HistoryStore()
    history.append(successfulRecord(output: "Earlier result"))
    let state = makeState(pasteboard: FailingPasteboard(), history: history)
    state.copyLastResult()
    precondition(state.pipelineState == .error("Clipboard could not be written"))
    return state
}

@MainActor
private func makeTestSettings() -> AppSettings {
    let suiteName = "SyrupAppStateTests.\(UUID().uuidString)"
    guard let userDefaults = UserDefaults(suiteName: suiteName) else {
        preconditionFailure("Unable to create isolated AppState test defaults")
    }
    userDefaults.removePersistentDomain(forName: suiteName)
    return AppSettings(
        userDefaults: userDefaults,
        defaultMicrophoneIDProvider: { "" }
    )
}

@MainActor
private func expectState(
    _ state: AppState,
    _ expectedState: AppState.PipelineState,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { state.pipelineState == expectedState }) { return }

    #expect(state.pipelineState == expectedState, sourceLocation: sourceLocation)
}

@MainActor
private func expectPasteboardWrites(
    _ pasteboard: SpyPasteboard,
    _ expectedWrites: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { pasteboard.writes == expectedWrites }) { return }

    #expect(pasteboard.writes == expectedWrites, sourceLocation: sourceLocation)
}

@MainActor
private func expectRecorderStartCount(
    _ recorder: FakeRecorder,
    _ expectedCount: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { recorder.startCallCount == expectedCount }) { return }

    #expect(recorder.startCallCount == expectedCount, sourceLocation: sourceLocation)
}

@MainActor
private func expectHistoryCount(
    _ history: HistoryStore,
    _ expectedCount: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { history.records.count == expectedCount }) { return }

    #expect(history.records.count == expectedCount, sourceLocation: sourceLocation)
}

@MainActor
private func expectArchiveDiscardCount(
    _ archive: SpyRecordingArchive,
    _ expectedCount: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { await archive.snapshot().discardedEntryIDs.count == expectedCount }) { return }

    #expect(
        await archive.snapshot().discardedEntryIDs.count == expectedCount,
        sourceLocation: sourceLocation
    )
}

@MainActor
private func expectAutoPasteCompleted(
    _ autoPaster: SpyAutoPaster,
    metrics: SpyPipelineMetrics,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, {
        autoPaster.pasteCount == 1
            && metrics.begunStages.contains(.autoPaste)
            && metrics.endedStages.contains(.autoPaste)
    }) { return }

    #expect(autoPaster.pasteCount == 1, sourceLocation: sourceLocation)
    #expect(metrics.begunStages.contains(.autoPaste), sourceLocation: sourceLocation)
    #expect(metrics.endedStages.contains(.autoPaste), sourceLocation: sourceLocation)
}

@MainActor
private func expectStreamingTypistStartCount(
    _ typist: SpyStreamingTypist,
    _ expectedCount: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { typist.startCount == expectedCount }) { return }

    #expect(typist.startCount == expectedCount, sourceLocation: sourceLocation)
}

@MainActor
private func expectMenuBarSymbol(
    _ state: AppState,
    _ expectedSymbol: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { state.menuBarSymbol == expectedSymbol }) { return }

    #expect(state.menuBarSymbol == expectedSymbol, sourceLocation: sourceLocation)
}
