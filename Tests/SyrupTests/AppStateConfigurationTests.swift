import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// Run configuration, provider selection, and latency stages.
@MainActor
struct AppStateConfigurationTests {
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
        await state.waitForPendingWork()

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
