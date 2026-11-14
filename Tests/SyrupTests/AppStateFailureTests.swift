import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// Failures: mapped errors, failed history, clipboard write failures, and the transcript fallback.
@MainActor
struct AppStateFailureTests {
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
    func contextualFailureNotificationExposesNoFallbackOrRetryActions() {
        let categoryIdentifier = AppFeedback.transformationFailureCategoryIdentifier(
            allowsTranscriptFallback: false,
            allowsRetry: false
        )

        #expect(categoryIdentifier == nil)
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
}
