import Foundation
import Testing
@testable import Syrup

@Suite(.serialized)
@MainActor
struct WorkflowAbilitiesTests {
    @Test func routingNormalizesAndMoves() throws {
        let a = workflow("A"), b = workflow("B")
        var list = WorkflowList(workflows: [a, b], appRouting: ["test.app": a.id, "stale": UUID()])
        #expect(list.appRouting == ["test.app": a.id])
        list.routeApplication("test.app", to: b.id)
        #expect(list.appRouting == ["test.app": b.id])
        list.deleteWorkflow(id: b.id)
        #expect(list.appRouting.isEmpty)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as? [String: Any])
        object["appRouting"] = ["stale": UUID().uuidString]
        let decoded = try JSONDecoder().decode(WorkflowList.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.appRouting.isEmpty)
        object.removeValue(forKey: "appRouting")
        object["version"] = 1
        let old = try JSONDecoder().decode(WorkflowList.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.workflows == list.workflows)
        #expect(old.appRouting.isEmpty)
    }

    @Test func primaryRoutesButDedicatedAndRevisionStayExplicit() async throws {
        let suite = testDomainName("WorkflowAbilities")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        let active = workflow("Active"), routed = workflow("Routed", locale: "en-US")
        settings.workflowList = WorkflowList(workflows: [active, routed])
        let before = settings.runConfiguration(workflowID: nil)
        #expect(settings.workflowList.routedWorkflowID(for: "test.app") == nil)
        #expect(settings.runConfiguration(workflowID: nil) == before)
        let transformer = QueuedTextTransformer(["one", "two", "three", "four"])
        let transcriber = QueuedTranscriber(["a", "b", "c", "d"])
        let clipboard = SpyPasteboard()
        let cue = WorkflowCue()
        var identityRequests: [Bool] = []
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(), transcriber: transcriber,
                             transformer: transformer, pasteboard: clipboard, feedback: SpyFeedback(),
                             maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock(),
                             recordingCue: cue,
                             frontmostApplication: { includeBundleID in
                                 identityRequests.append(includeBundleID)
                                 return ("test.app", nil)
                             })
        await dictate(state)
        settings.workflowList.routeApplication("test.app", to: routed.id)
        await dictate(state)
        await dictate(state, workflowID: active.id)
        state.startRevision()
        await Task.yield()
        state.revisionTriggerReleased()
        await settle(state)
        let locales = await transcriber.localeIdentifiers
        #expect(locales.map { $0.replacingOccurrences(of: "_", with: "-") } == ["pt-BR", "en-US", "pt-BR", "pt-BR"])
        let instructions = await transformer.receivedInstructions
        #expect(instructions[0].contains("Active"))
        #expect(instructions[1].contains("Routed"))
        #expect(instructions[2].contains("Active"))
        #expect(instructions[3].contains("Revise"))
        #expect(instructions.allSatisfy { !$0.contains("test.app") })
        #expect(clipboard.writes.count == 4)
        #expect(cue.states.contains(.recording(caption: "Routed")))
        #expect(identityRequests.filter { $0 }.count == 4, "The routing lookup plus one after each counted dictation")
        #expect(state.usageStats.stats.wordsByApp.keys.sorted() == ["test.app"])
        #expect(state.usageStats.stats.totalWords == 3, "The revision's spoken adjustment is not dictation")
        #expect(!String(describing: before).contains("test.app"))
        #expect(settings.activeWorkflow.id == active.id)
    }

    @Test(arguments: [true, false], [PasteStrategy.commandV(9), .typeText])
    func transcriptionBypassesBrokenProviderAndDeliversAtomically(cleanup: Bool, strategy: PasteStrategy) async throws {
        let suite = testDomainName("WorkflowAbilities")
        let defaults = TestDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appending(path: suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.baseURL = "broken://offline"
        settings.codexPath = "/no/such/provider"
        settings.translationProvider = .openAICompatible
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        await settings.attachedOptIns(history: enabledHistoryStore()).setPersistHistory(true)
        settings.addWorkflow(from: WorkflowTemplate(id: "local", name: "Local", kind: .transcribeOnly(cleanup: cleanup)))
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.dictationLocaleID = "en-US" }
        let clipboard = SpyPasteboard(), paster = SpyAutoPaster(), typist = SpyStreamingTypist()
        paster.strategy = strategy
        let history = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        let feedback = SpyFeedback()
        let state = AppState.fixture(settings: settings, history: history,
                             keychainStore: KeychainStore(storageDirectory: directory.appending(path: "secrets")),
                             audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("  Um, hello  ")),
                             transformerProvider: UntouchableProvider(), pasteboard: clipboard, feedback: feedback,
                             autoPaster: paster, streamingTypistFactory: { typist },
                             maximumRecordingDurationNanoseconds: 0, autoPasteDelayNanoseconds: 0,
                             recordingClock: FastForwardClock(),
                             captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) })
        await dictate(state)
        let expected = cleanup ? "Hello" : "Um, hello"
        #expect(clipboard.writes == [expected])
        switch strategy {
        case .commandV:
            #expect(paster.pasteCount == 1)
            #expect(typist.startCount == 0)
        case .typeText:
            #expect(paster.pasteCount == 0)
            #expect(typist.appendedDeltas == [expected])
            #expect(typist.finishCount == 1)
        }
        #expect(feedback.successSoundCount == 1)
        #expect(state.pipelineState == .idle)
        let record = try #require(history.records.first)
        #expect(record.output == expected)
        #expect(record.transcript == "Um, hello")
        #expect(record.provider == nil)
        #expect(record.transformation == .contextual(workflowName: "Local", instruction: ""))
        #expect(record.canRetry == false)
        #expect(!record.canRetry && !record.canUseTranscriptFallback)
        let failed = DictationRecord(id: UUID(), finishedAt: record.finishedAt, transcript: record.transcript,
                                     output: nil, transformation: record.transformation, outcome: .failed(message: "failure"))
        #expect(!failed.canRetry && !failed.canUseTranscriptFallback)
        await history.flush()
        #expect(HistoryStore(persistenceEnabled: true, storageDirectory: directory).records == [record])
        state.retryTranslation(recordID: record.id, using: .codexCLI)
        #expect(state.pipelineState == .idle)
        #expect(clipboard.writes == [expected])
    }

    @Test func cancelTranscriptionNeverWrites() async {
        let suite = testDomainName("WorkflowAbilities")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.addWorkflow(from: WorkflowTemplate(id: "local", name: "Local", kind: .transcribeOnly(cleanup: true)))
        let clipboard = SpyPasteboard(), transcriber = FakeTranscriber(.suspended)
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(), transcriber: transcriber,
                             transformerProvider: UntouchableProvider(), pasteboard: clipboard,
                             feedback: SpyFeedback(), maximumRecordingDurationNanoseconds: 0,
                             recordingClock: FastForwardClock())
        state.triggerPressed()
        await transcriber.waitForCall()
        state.cancelRequested()
        await transcriber.waitForCancellation()
        #expect(clipboard.writes.isEmpty)
        #expect(state.history.records.isEmpty)
    }

    @Test func cleanupEmptyUsesExistingEmptyTranscriptOutcome() async {
        let suite = testDomainName("WorkflowAbilities")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.addWorkflow(from: WorkflowTemplate(id: "local", name: "Local", kind: .transcribeOnly(cleanup: true)))
        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.dictationLocaleID = "en-US" }
        let clipboard = SpyPasteboard()
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("Um...")),
                             transformerProvider: UntouchableProvider(), pasteboard: clipboard,
                             feedback: SpyFeedback(), maximumRecordingDurationNanoseconds: 0,
                             recordingClock: FastForwardClock())
        await dictate(state)
        #expect(state.pipelineState == .error(userMessage(for: PipelineError.emptyTranscript)))
        #expect(clipboard.writes.isEmpty)
        #expect(state.history.records.isEmpty)
    }

    @Test func reviseTranscriptionUsesConfiguredProvider() async throws {
        let suite = testDomainName("WorkflowAbilities")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.addWorkflow(from: WorkflowTemplate(id: "local", name: "Local", kind: .transcribeOnly(cleanup: false)))
        let transcriber = QueuedTranscriber(["original words", "make it shorter"])
        let transformer = QueuedTextTransformer(["shorter"]), clipboard = SpyPasteboard()
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(), transcriber: transcriber,
                             transformer: transformer, pasteboard: clipboard, feedback: SpyFeedback(),
                             maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
        await dictate(state)
        #expect(await transformer.receivedTexts.isEmpty)
        state.revisionTriggerPressed()
        await Task.yield()
        state.revisionTriggerReleased()
        await settle(state)
        #expect(await transformer.receivedTexts == ["original words"])
        #expect(clipboard.writes == ["original words", "shorter"])
        let record = try #require(state.history.records.first)
        #expect(record.provider == settings.translationProvider)
        guard case .revision = record.transformation else { Issue.record("Expected revision"); return }
    }

    @Test func allKindsRoundTripAndTranscriptionCannotCaptureSelection() throws {
        for kind in [WorkflowKind.translation(targetLanguage: "English", tonePreset: .neutral, customToneText: ""),
                     .custom(instruction: "polish", enforceOutputContract: true), .transcribeOnly(cleanup: true),
                     .transcribeOnly(cleanup: false)] {
            let original = Workflow(id: UUID(), name: "Test", kind: kind, dictationLocaleID: "en-US",
                                    translationProvider: nil)
            #expect(try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(original)) == original)
        }
        var local = Workflow(id: UUID(), name: "Local", kind: .transcribeOnly(cleanup: true),
                             dictationLocaleID: "en-US", translationProvider: .codexCLI,
                             input: .selection, includeSelectionContext: true)
        local.input = .selection
        local.includeSelectionContext = true
        #expect(local.input == .voice && !local.includeSelectionContext)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as? [String: Any])
        object["input"] = "selection"
        object["includeSelectionContext"] = true
        let decoded = try JSONDecoder().decode(Workflow.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.input == .voice && !decoded.includeSelectionContext)
        #expect(decoded.translationProvider == nil)
    }

    @Test func migrationPreservesOldBlobAndFutureBlobIsReadOnly() throws {
        let suite = testDomainName("WorkflowAbilities")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var list = WorkflowList(workflows: [workflow("Legacy")])
        list.version = 1
        let legacy = try JSONEncoder().encode(list)
        defaults.set(legacy, forKey: "workflowListV1")
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        #expect(settings.workflowList.workflows == list.workflows)
        #expect(settings.workflowList.version == 3)
        settings.addWorkflow(from: WorkflowTemplate(id: "local", name: "Local", kind: .transcribeOnly(cleanup: true)))
        let newBlob = try #require(defaults.data(forKey: "workflowListV3"))
        #expect(defaults.data(forKey: "workflowListV1") == legacy)
        #expect(try JSONDecoder().decode(LegacyWorkflowList.self, from: legacy).workflows.count == 1)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(LegacyWorkflowList.self, from: newBlob)
        }
        #expect(try JSONDecoder().decode(WorkflowList.self, from: newBlob).workflows.count == 2)
        let future = Data(#"{"version":99,"workflows":[{"kind":{"unknown":{}}}]}"#.utf8)
        defaults.set(future, forKey: "workflowListV3")
        let futureSettings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        futureSettings.updateWorkflow(id: futureSettings.activeWorkflow.id) { $0.name = "Changed" }
        #expect(defaults.data(forKey: "workflowListV3") == future)
    }

    @Test func onlyConfiguredRoutesWarmInactiveLocales() async {
        let suite = testDomainName("WorkflowAbilities")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        let active = workflow("Active"), routed = workflow("Routed", locale: "fr-FR")
        settings.workflowList = WorkflowList(workflows: [active, routed])
        let probe = LocaleProbe()
        let manager = TranscriberAssetManager(prepare: { locale in
            await probe.record(locale)
            return .installed(locale)
        })
        let state = AppState.fixture(settings: settings, transcriberAssetManager: manager,
                             audioRecorder: FakeRecorder(), transcriber: FakeTranscriber(.success("text")),
                             transformer: FakeTextTransformer(.failure(.transformer)),
                             pasteboard: SpyPasteboard(), feedback: SpyFeedback())
        state.refreshWorkflowHotkeys()
        await eventually { await probe.locales.count == 1 }
        #expect(await probe.locales == ["pt-BR"])
        settings.workflowList.routeApplication("test.app", to: routed.id)
        state.refreshWorkflowHotkeys()
        await eventually { await probe.locales.count == 2 }
        #expect(await Set(probe.locales) == ["pt-BR", "fr-FR"])
    }

    @Test(arguments: [WorkflowKind.custom(instruction: "polish", enforceOutputContract: true),
                      .transcribeOnly(cleanup: true), .transcribeOnly(cleanup: false)])
    func correctionsAreCapturedBeforeTransformationAndCleanup(_ kind: WorkflowKind) async throws {
        let suite = testDomainName("Corrections")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.addWorkflow(from: WorkflowTemplate(id: "correct", name: "Correct", kind: kind))
        let id = settings.activeWorkflow.id
        settings.updateWorkflow(id: id) {
            $0.dictationLocaleID = "en-US"
            $0.corrections = [.init(heard: "open code", replacement: "um OpenCode")]
        }
        let transformer = QueuedTextTransformer(["transformed"])
        let clipboard = SpyPasteboard()
        let state = AppState.fixture(settings: settings, audioRecorder: FakeRecorder(),
                             transcriber: FakeTranscriber(.success("open code")), transformer: transformer,
                             pasteboard: clipboard, feedback: SpyFeedback(),
                             maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
        state.triggerPressed()
        settings.updateWorkflow(id: id) { $0.corrections = [] }
        await Task.yield()
        state.triggerReleased()
        await settle(state)
        switch kind {
        case .transcribeOnly(let cleanup, _):
            #expect(clipboard.writes == [cleanup ? "OpenCode" : "um OpenCode"])
            #expect(await transformer.receivedTexts.isEmpty)
        default:
            #expect(await transformer.receivedTexts == ["um OpenCode"])
            #expect(clipboard.writes == ["transformed"])
        }
    }

    private func workflow(_ name: String, locale: String = "pt-BR") -> Workflow {
        Workflow(id: UUID(), name: name, kind: .custom(instruction: name, enforceOutputContract: true),
                 dictationLocaleID: locale, translationProvider: nil)
    }

    private func dictate(_ state: AppState, workflowID: UUID? = nil) async {
        state.triggerPressed(workflowID: workflowID)
        await Task.yield()
        state.triggerReleased(workflowID: workflowID)
        await settle(state)
    }

    private func settle(_ state: AppState) async {
        await settleRun(state)
    }
}

private struct UntouchableProvider: TransformerSource {
    @MainActor func snapshot(for provider: TranslationProvider) -> TransformerSnapshot {
        Issue.record("Transcribe-only resolved provider configuration")
        return TransformerSnapshot { [self] instruction in
            await transformer(for: provider, instruction: instruction)
        }
    }
    func transformer(for provider: TranslationProvider, instruction: String) async -> any TextTransformer {
        Issue.record("Transcribe-only prepared a provider")
        return UntouchableTransformer()
    }
}

private struct UntouchableTransformer: TextTransformer {
    func transform(_ text: String, instruction: String) async throws -> String {
        Issue.record("Transcribe-only called a transformer")
        throw FakeFailure.transformer
    }
}

private actor LocaleProbe {
    private(set) var locales: [String] = []
    func record(_ locale: String) { locales.append(locale) }
}

@MainActor
private final class WorkflowCue: RecordingCuePresenting {
    var states: [RecordingCueState] = []
    func apply(_ state: RecordingCueState) { states.append(state) }
    func updateLevel(_ level: Double) {}
    func updateTranscript(_ text: String) {}
}

private struct LegacyWorkflowList: Decodable {
    struct LegacyWorkflow: Decodable {
        let kind: LegacyKind
    }
    enum LegacyKind: Decodable {
        case translation(targetLanguage: String, tonePreset: TonePreset, customToneText: String)
        case custom(instruction: String, enforceOutputContract: Bool)
    }
    let workflows: [LegacyWorkflow]
}
