import Foundation
import Testing
@testable import Syrup

@MainActor
struct AppSettingsTests {
    @Test
    func defaultSettingsUseMilestone7Values() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(settings.hotkeyMode == .hold)
        #expect(settings.dictationLocaleID == AppSettings.defaultDictationLocaleID)
        #expect(settings.targetLanguage == "English")
        #expect(settings.tonePreset == .neutral)
        #expect(settings.customToneText == "")
        #expect(settings.baseURL == AppSettings.defaultBaseURL)
        #expect(settings.modelName == AppSettings.defaultModelName)
        #expect(settings.translationProvider == .openAICompatible)
        #expect(settings.codexPath == "")
        #expect(settings.codexModel == AppSettings.defaultCodexModel)
        #expect(settings.playSounds)
        #expect(settings.successSound == .chime)
        #expect(settings.lowerOtherAudioWhileRecording == false)
        #expect(settings.autoPasteEnabled == false)
        #expect(settings.streamingDeliveryEnabled == false)
        #expect(settings.persistHistory == false)
        #expect(settings.showRecordingCue)
        #expect(settings.includeCommonTechTerms)
        #expect(settings.glossaryLearningEnabled == false)
        #expect(settings.glossaryProposals == GlossaryProposalList())
        #expect(settings.showLiveTranscript)
        #expect(settings.workflowList.workflows.count == 1)
        #expect(settings.activeWorkflow.name == "Translate")
        #expect(settings.maximumRecordingDurationSeconds == AppSettings.defaultMaximumRecordingDurationSeconds)
        #expect(settings.maximumRecordingDurationNanoseconds == 120_000_000_000)
        #expect(userDefaults.string(forKey: "dictationLocaleID") == AppSettings.defaultDictationLocaleID)
        #expect(userDefaults.bool(forKey: AppSettings.dictationDefaultMigrationMarkerKey))
    }

    @Test
    func glossaryProposalsPersistAndReloadAsVersionedBlob() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        let open = GlossaryProposal(
            id: UUID(),
            term: "Syrup",
            mishearings: ["sirup"],
            confidence: 0.8,
            createdAt: Date(timeIntervalSince1970: 123)
        )
        let dismissed = GlossaryProposal(
            id: UUID(),
            term: "Codex",
            mishearings: ["code ex"],
            confidence: 0.9,
            createdAt: Date(timeIntervalSince1970: 456)
        )

        #expect(settings.addGlossaryProposal(open))
        #expect(settings.addGlossaryProposal(dismissed))
        settings.dismissGlossaryProposal(id: dismissed.id)

        let reloaded = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        let data = try #require(userDefaults.data(forKey: "glossaryProposalsV1"))
        let decoded = try JSONDecoder().decode(GlossaryProposalList.self, from: data)

        #expect(reloaded.glossaryProposals == settings.glossaryProposals)
        #expect(decoded == settings.glossaryProposals)
        #expect(reloaded.glossaryProposals.proposals == [open])
        #expect(reloaded.glossaryProposals.dismissedKeys == ["codex"])
    }

    @Test
    func milestone7SettingsPersistRawValuesInUserDefaults() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        settings.hotkeyMode = .toggle
        settings.dictationLocaleID = "pt-BR"
        settings.targetLanguage = "German"
        settings.tonePreset = .custom
        settings.customToneText = "Use a formal register."
        settings.baseURL = "http://localhost:11434/v1"
        settings.modelName = "llama3.2"
        settings.translationProvider = .codexCLI
        settings.codexPath = "/example/bin/codex"
        settings.codexModel = "gpt-5.4-mini"
        settings.playSounds = false
        settings.lowerOtherAudioWhileRecording = true
        settings.autoPasteEnabled = true
        settings.streamingDeliveryEnabled = true
        await settings.privacyOptIns(history: enabledHistoryStore()).setPersistHistory(true)
        settings.showRecordingCue = false
        settings.includeCommonTechTerms = false
        settings.setGlossaryLearningForTesting(true)
        settings.showLiveTranscript = false
        settings.maximumRecordingDurationSeconds = 180
        settings.selectedMicrophoneID = "input-device-uid"

        let reloadedSettings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(reloadedSettings.hotkeyMode == .toggle)
        #expect(reloadedSettings.dictationLocaleID == "pt-BR")
        #expect(reloadedSettings.targetLanguage == "German")
        #expect(reloadedSettings.tonePreset == .custom)
        #expect(reloadedSettings.customToneText == "Use a formal register.")
        #expect(reloadedSettings.baseURL == "http://localhost:11434/v1")
        #expect(reloadedSettings.modelName == "llama3.2")
        #expect(reloadedSettings.translationProvider == .codexCLI)
        #expect(reloadedSettings.codexPath == "/example/bin/codex")
        #expect(reloadedSettings.codexModel == "gpt-5.4-mini")
        #expect(reloadedSettings.playSounds == false)
        #expect(reloadedSettings.lowerOtherAudioWhileRecording)
        #expect(reloadedSettings.autoPasteEnabled)
        #expect(reloadedSettings.streamingDeliveryEnabled)
        #expect(reloadedSettings.persistHistory)
        #expect(reloadedSettings.showRecordingCue == false)
        #expect(reloadedSettings.includeCommonTechTerms == false)
        #expect(reloadedSettings.glossaryLearningEnabled)
        #expect(reloadedSettings.showLiveTranscript == false)
        #expect(reloadedSettings.maximumRecordingDurationSeconds == 180)
        #expect(reloadedSettings.selectedMicrophoneID == "input-device-uid")
        #expect(userDefaults.string(forKey: "hotkeyMode") == "toggle")
        #expect(userDefaults.string(forKey: "tonePreset") == "custom")
        #expect(userDefaults.string(forKey: "baseURL") == "http://localhost:11434/v1")
        #expect(userDefaults.string(forKey: "translationProvider") == "codex_cli")
        #expect(userDefaults.object(forKey: "lowerOtherAudioWhileRecording") as? Bool == true)
        #expect(userDefaults.bool(forKey: "autoPasteEnabled"))
        #expect(userDefaults.bool(forKey: "streamingDeliveryEnabled"))
        #expect(userDefaults.bool(forKey: "persistHistory"))
        #expect(userDefaults.bool(forKey: "includeCommonTechTerms") == false)
        #expect(userDefaults.bool(forKey: "glossaryLearningEnabled"))
        #expect(userDefaults.string(forKey: "codexPath") == "/example/bin/codex")
        #expect(userDefaults.string(forKey: "codexModel") == "gpt-5.4-mini")
        #expect(userDefaults.integer(forKey: "maximumRecordingDurationSeconds") == 180)
        #expect(userDefaults.object(forKey: "apiKey") == nil)
    }

    @Test
    func disablingGlossaryLearningDeletesPendingRecordings() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        let archive = SpyRecordingArchive()
        let optIns = settings.privacyOptIns(recordingArchive: archive)

        await optIns.setGlossaryLearning(true).value
        #expect(await archive.snapshot().deleteAllCount == 0)

        await optIns.setGlossaryLearning(false).value
        #expect(await archive.snapshot().deleteAllCount == 1)
    }

    @Test(arguments: [false, true])
    func turningLearningOffDeletesRecordingsWithoutAnyView(deletionFails: Bool) async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        settings.setGlossaryLearningForTesting(true)
        let archive = deletionFails ? SpyRecordingArchive(deleteAllError: .deleteAllFailed(code: 513)) : SpyRecordingArchive()

        let deletion = settings.privacyOptIns(recordingArchive: archive).setGlossaryLearning(false)
        #expect(settings.glossaryLearningEnabled == false)
        await deletion.value

        #expect(await archive.snapshot().deleteAllCount == 1)
        #expect(settings.glossaryLearningEnabled == deletionFails)
    }

    @Test
    func failedStartupCleanupNeverEnablesGlossaryLearning() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        let archive = SpyRecordingArchive(deleteAllError: .deleteAllFailed(code: 513))

        await deleteLeftoverRecordingsIfLearningIsOff(settings: settings, recordingArchive: archive)

        #expect(settings.glossaryLearningEnabled == false)
        #expect(await archive.snapshot().deleteAllCount == 1)
    }

    /// Off, on, off again: the first deletion fails after the second succeeded. The person's latest
    /// choice, off, stands.
    @Test
    func anOlderFailedOptOutCannotUndoANewerOne() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        let archive = SpyRecordingArchive(holdsFirstDeleteAllThenFails: true)
        let optIns = settings.privacyOptIns(recordingArchive: archive)
        optIns.setGlossaryLearning(true)

        let first = optIns.setGlossaryLearning(false)
        await archive.firstDeleteAllStarted()
        optIns.setGlossaryLearning(true)
        let second = optIns.setGlossaryLearning(false)
        await second.value
        archive.releaseFirstDeleteAll()
        await first.value

        #expect(await archive.snapshot().deleteAllCount == 2)
        #expect(settings.glossaryLearningEnabled == false)
    }

    /// Off, then on again before the deletion started: nothing is deleted, so a recording made after
    /// turning learning back on survives.
    @Test
    func anOptOutSupersededBeforeItsDeletionStartsDeletesNothing() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        let archive = SpyRecordingArchive()
        let optIns = settings.privacyOptIns(recordingArchive: archive)
        optIns.setGlossaryLearning(true)

        let off = optIns.setGlossaryLearning(false)
        optIns.setGlossaryLearning(true)
        await off.value

        #expect(await archive.snapshot().deleteAllCount == 0)
        #expect(settings.glossaryLearningEnabled)
    }

    /// The language check awaits Speech. A workflow switch meanwhile must not move the replacement
    /// onto the newly active workflow.
    @Test
    func aDictationLocaleReplacementStaysOnTheWorkflowItWasFoundFor() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        let first = settings.activeWorkflow.id
        settings.updateWorkflow(id: first) { $0.dictationLocaleID = "xx-XX" }
        let second = settings.addWorkflow(from: WorkflowTemplate(id: "other", name: "Other", kind: .transcribeOnly(cleanup: false)))
        settings.updateWorkflow(id: second) { $0.dictationLocaleID = "pt-BR" }
        settings.setActiveWorkflowID(first)

        await settings.refreshActiveDictationLocale { localeID in
            #expect(localeID == "xx-XX")
            settings.setActiveWorkflowID(second)
            return "en-US"
        }

        #expect(settings.workflow(id: first).dictationLocaleID == "en-US")
        #expect(settings.workflow(id: second).dictationLocaleID == "pt-BR")
    }

    @Test
    func aDictationLocaleEditedDuringTheCheckIsKept() async throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        let workflow = settings.activeWorkflow.id
        settings.updateWorkflow(id: workflow) { $0.dictationLocaleID = "xx-XX" }

        await settings.refreshActiveDictationLocale { _ in
            settings.updateWorkflow(id: workflow) { $0.dictationLocaleID = "fr-FR" }
            return "en-US"
        }

        #expect(settings.workflow(id: workflow).dictationLocaleID == "fr-FR")
    }

    @Test
    func invalidPersistedEnumValuesFallBackToSafeDefaults() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults.set("sideways", forKey: "hotkeyMode")
        userDefaults.set("verbose-but-not-a-preset", forKey: "tonePreset")
        userDefaults.set("backend-api", forKey: "translationProvider")

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(settings.hotkeyMode == .hold)
        #expect(settings.tonePreset == .neutral)
        #expect(settings.translationProvider == .openAICompatible)
    }

    @Test
    func translationProviderLatencyHintsExplainFastAndSlowPaths() {
        #expect(TranslationProvider.openAICompatible.latencyHint == "Low latency: direct API request.")
        #expect(TranslationProvider.codexCLI.latencyHint == "Slower: launches the Codex CLI for each translation.")
        #expect(TranslationProvider.appleOnDevice.latencyHint == "Fast and private: runs entirely on this Mac.")
    }

    @Test
    func workflowListMigratesFromFlatSettingsAndPersistsAsBlob() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults.set("German", forKey: "targetLanguage")
        userDefaults.set("custom", forKey: "tonePreset")
        userDefaults.set("Use a formal register.", forKey: "customToneText")
        userDefaults.set("fr-FR", forKey: "dictationLocaleID")

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(settings.activeWorkflow.name == "Translate")
        #expect(settings.activeWorkflow.dictationLocaleID == "fr-FR")
        #expect(settings.activeWorkflow.kind == .translation(
            targetLanguage: "German",
            tonePreset: .custom,
            customToneText: "Use a formal register."
        ))
        #expect(userDefaults.data(forKey: "workflowListV3") != nil)
    }

    @Test
    func versionOneWorkflowBlobUpgradesWithoutLosingWorkflows() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let workflowID = "00000000-0000-0000-0000-000000000001"
        let blob = Data(
            #"{"version":1,"workflows":[{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy Polish","kind":{"custom":{"instruction":"Polish this.","enforceOutputContract":true}},"dictationLocaleID":"pt-BR","translationProvider":null}],"activeWorkflowID":"00000000-0000-0000-0000-000000000001"}"#.utf8
        )
        userDefaults.set(blob, forKey: "workflowListV1")

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(settings.workflowList.version == 3)
        #expect(settings.activeWorkflow.id == UUID(uuidString: workflowID))
        #expect(settings.activeWorkflow.name == "Legacy Polish")

        let upgradedData = try #require(userDefaults.data(forKey: "workflowListV3"))
        let upgraded = try JSONDecoder().decode(WorkflowList.self, from: upgradedData)
        #expect(upgraded.version == 3)
        #expect(upgraded.workflows.map(\.name) == ["Legacy Polish"])
    }

    @Test
    func versionTwoWorkflowBlobDecodesThroughMigrationScaffold() throws {
        let blob = Data(
            #"{"version":2,"workflows":[{"id":"00000000-0000-0000-0000-000000000001","name":"Pre-Context Workflow","kind":{"custom":{"instruction":"Polish this.","enforceOutputContract":true}},"dictationLocaleID":"pt-BR","translationProvider":null}],"activeWorkflowID":"00000000-0000-0000-0000-000000000001"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(WorkflowList.self, from: blob)
        let workflow = try #require(decoded.workflows.first)

        #expect(decoded.version == 2)
        #expect(workflow.name == "Pre-Context Workflow")
        #expect(workflow.dictationLocaleID == "pt-BR")
        #expect(workflow.translationProvider == nil)
        #expect(workflow.input == .voice)
        #expect(workflow.includeSelectionContext == false)
    }

    @Test
    func contextualRunSnapshotExcludesCapturedSelection() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        settings.addGlossaryTerm(GlossaryTerm(term: "Syrup", mishearings: ["sirup"]))
        let workflowKind = WorkflowKind.custom(
            instruction: "Draft a concise reply.",
            enforceOutputContract: true
        )
        settings.updateWorkflow(id: settings.activeWorkflow.id) { workflow in
            workflow.name = "Reply Draft"
            workflow.kind = workflowKind
            workflow.includeSelectionContext = true
        }

        let configuration = settings.runConfiguration(
            workflowID: nil,
            contextText: "private selected text"
        )
        let snapshotInstruction: String
        switch configuration.transformation {
        case .contextual(let workflowName, let instruction):
            #expect(workflowName == "Reply Draft")
            snapshotInstruction = instruction
        case .translation, .custom, .revision:
            Issue.record("Expected a contextual snapshot")
            return
        }

        #expect(configuration.instruction.contains("private selected text"))
        #expect(configuration.instruction.contains("- Syrup"))
        #expect(configuration.speechVocabulary.first == "Syrup")
        #expect(configuration.speechVocabulary.dropFirst().first == "deploy")
        #expect(configuration.speechVocabulary.count == PromptBuilder.maximumGlossaryTerms)
        #expect(snapshotInstruction == PromptBuilder.instruction(
            for: workflowKind,
            glossary: settings.glossaryList
        ))
        #expect(snapshotInstruction.contains("private selected text") == false)
        let snapshotData = try JSONEncoder().encode(configuration.transformation)
        #expect(String(decoding: snapshotData, as: UTF8.self).contains("private selected text") == false)
    }

    @Test
    func runConfigurationDefaultsToDictationWithoutCapturedContext() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        let configuration = settings.runConfiguration(workflowID: nil)

        #expect(configuration.purpose == .dictation)
        #expect(configuration.contextText == nil)
        #expect(configuration.speechVocabulary == Array(
            CommonTechTerms.terms.prefix(PromptBuilder.maximumGlossaryTerms)
        ))
    }

    @Test
    func workflowMutationsPreserveLastWorkflowInvariant() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        let originalID = settings.activeWorkflow.id

        settings.deleteWorkflow(id: originalID)
        #expect(settings.workflowList.workflows.count == 1)

        settings.addWorkflow(from: WorkflowTemplate.templates()[1])
        #expect(settings.workflowList.workflows.count == 2)
        #expect(settings.activeWorkflow.name == "Polish")

        settings.updateWorkflow(id: settings.activeWorkflow.id) { workflow in
            workflow.input = .selection
            workflow.includeSelectionContext = true
        }

        settings.duplicateWorkflow(id: settings.activeWorkflow.id)
        #expect(settings.workflowList.workflows.count == 3)
        #expect(settings.activeWorkflow.name == "Polish Copy")
        #expect(settings.activeWorkflow.input == .selection)
        #expect(settings.activeWorkflow.includeSelectionContext)
    }

    @Test(arguments: [
        "en",
        "en-US",
        "en_US",
    ])
    func accidentalEnglishDictationDefaultMigratesOnceToPortugueseBrazil(englishLocaleID: String) throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults.set(englishLocaleID, forKey: "dictationLocaleID")

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(settings.dictationLocaleID == AppSettings.defaultDictationLocaleID)
        #expect(userDefaults.string(forKey: "dictationLocaleID") == AppSettings.defaultDictationLocaleID)
        #expect(userDefaults.bool(forKey: AppSettings.dictationDefaultMigrationMarkerKey))

        settings.dictationLocaleID = "en-US"
        let reloadedSettings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(reloadedSettings.dictationLocaleID == "en-US")
    }

    @Test
    func nonEnglishDictationLocaleSurvivesPortugueseDefaultMigration() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults.set("fr-FR", forKey: "dictationLocaleID")

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(settings.dictationLocaleID == "fr-FR")
        #expect(userDefaults.string(forKey: "dictationLocaleID") == "fr-FR")
        #expect(userDefaults.bool(forKey: AppSettings.dictationDefaultMigrationMarkerKey))
    }

    @Test
    func toneInstructionBridgesPresetAndCustomStorage() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        settings.toneInstruction = TonePreset.concise.instruction()
        #expect(settings.tonePreset == .concise)
        #expect(settings.toneInstruction == TonePreset.concise.instruction())

        settings.toneInstruction = "Sound like a concise support reply."
        #expect(settings.tonePreset == .custom)
        #expect(settings.customToneText == "Sound like a concise support reply.")
        #expect(settings.toneInstruction == "Sound like a concise support reply.")
    }

    @Test
    func selectedMicrophoneIDPersistsInUserDefaults() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        #expect(settings.selectedMicrophoneID == "")

        settings.selectedMicrophoneID = "input-device-uid"

        let reloadedSettings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        #expect(reloadedSettings.selectedMicrophoneID == "input-device-uid")
    }

    @Test
    func selectedMicrophoneIDDefaultsToBuiltInMicrophoneWhenAvailable() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "BuiltInMicrophoneDevice" }
        )

        #expect(settings.selectedMicrophoneID == "BuiltInMicrophoneDevice")
        #expect(userDefaults.string(forKey: "selectedMicrophoneID") == "BuiltInMicrophoneDevice")
    }

    @Test
    func playSoundsPersistsInUserDefaults() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        #expect(settings.playSounds)

        settings.playSounds = false

        let reloadedSettings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        #expect(reloadedSettings.playSounds == false)
    }

    @Test
    func successSoundPersistsAndFallsBackToDefault() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        settings.successSound = .drop
        #expect(userDefaults.string(forKey: "successSound") == "drop")

        let reloaded = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        #expect(reloaded.successSound == .drop)

        userDefaults.set("not-a-real-sound", forKey: "successSound")
        let recovered = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        #expect(recovered.successSound == .default)
    }

    @Test
    func maximumRecordingDurationIsClampedAndPersisted() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        userDefaults.set(0, forKey: "maximumRecordingDurationSeconds")

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        #expect(settings.maximumRecordingDurationSeconds == AppSettings.minimumRecordingDurationSeconds)
        #expect(userDefaults.integer(forKey: "maximumRecordingDurationSeconds") == AppSettings.minimumRecordingDurationSeconds)

        settings.maximumRecordingDurationSeconds = 9_999
        #expect(settings.maximumRecordingDurationSeconds == AppSettings.maximumRecordingDurationSecondsLimit)
        #expect(userDefaults.integer(forKey: "maximumRecordingDurationSeconds") == AppSettings.maximumRecordingDurationSecondsLimit)
    }
}
