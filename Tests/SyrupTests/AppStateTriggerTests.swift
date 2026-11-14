import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// Hotkey, menu, and Esc events across pipeline states, recording limits, and error reset.
@MainActor
struct AppStateTriggerTests {
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
        await state.waitForPendingWork()

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
        await state.waitForPendingWork()

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
        await state.waitForPendingWork()

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
        // Resuming the stale reset queued its last step on the main actor; one more main-actor hop
        // runs after it, so the check below sees what that step did.
        await Task { @MainActor in }.value

        #expect(state.pipelineState == .error("Something went wrong"))

        state.cancelRequested()
        await sleeper.resumeAll(throwing: CancellationError())
    }
}
