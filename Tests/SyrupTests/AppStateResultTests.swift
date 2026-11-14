import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// Last result, Copy Last, success feedback, and Retry.
@MainActor
struct AppStateResultTests {
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
}
