import Foundation
import Testing
@testable import Syrup

@MainActor
struct HomeStatusTests {
    @Test
    func headlineMatchesHowTheShortcutWorks() {
        typealias Headline = HomeStatus.Headline
        #expect(HomeStatus.headline(phase: .idle, input: .voice, mode: .hold, hasShortcut: true) == Headline(before: "Hold", after: "and speak"))
        #expect(HomeStatus.headline(phase: .idle, input: .voice, mode: .toggle, hasShortcut: true) == Headline(before: "Press", after: "and speak"))
        #expect(HomeStatus.headline(phase: .idle, input: .selection, mode: .hold, hasShortcut: true) == Headline(before: "Select text, then press"))
        #expect(HomeStatus.headline(phase: .recording, input: .voice, mode: .hold, hasShortcut: true) == Headline(before: "Listening. Release", after: "to finish"))
        #expect(HomeStatus.headline(phase: .recording, input: .voice, mode: .toggle, hasShortcut: true) == Headline(before: "Listening. Press", after: "to finish"))
        #expect(HomeStatus.headline(phase: .idle, input: .voice, mode: .hold, hasShortcut: false).showsShortcut == false)
        #expect(HomeStatus.headline(phase: .error("No speech"), input: .voice, mode: .hold, hasShortcut: true) == Headline(before: "No speech", showsShortcut: false))
    }

    @Test
    func outcomeSaysWhereTheResultGoes() {
        let translate = WorkflowKind.translation(targetLanguage: "English", tonePreset: .neutral, customToneText: "")
        #expect(HomeStatus.outcome(kind: translate, pastes: true) == "Syrup translates it and pastes it where your cursor is.")
        #expect(HomeStatus.outcome(kind: translate, pastes: false) == "Syrup translates it and copies it to the clipboard.")
    }

    @Test
    func missingAccessibilityOnlyMattersWhenPasting() {
        var inputs = HomeStatus.Inputs(accessibility: .notRequested)
        #expect(HomeStatus.attentionItems(inputs).isEmpty)
        inputs.autoPasteEnabled = true
        #expect(HomeStatus.attentionItems(inputs).map(\.action) == [.open(.privacy)])
    }

    @Test
    func voicePermissionsAndLanguageDoNotMatterForSelectionWorkflows() {
        var inputs = HomeStatus.Inputs(
            microphone: .denied,
            speech: .denied,
            localeState: .failed("Portuguese"),
            localeMessage: "Portuguese language model could not be installed",
            speechModelName: "Parakeet Ultra"
        )
        #expect(HomeStatus.attentionItems(inputs).count == 4)
        inputs.usesVoice = false
        #expect(HomeStatus.attentionItems(inputs).isEmpty)
    }

    @Test
    func onlyWarningsChangeTheStatus() {
        let info = HomeStatus.AttentionItem(message: "1 suggestion", severity: .info, action: .open(.glossary))
        let warning = HomeStatus.AttentionItem(message: "Set up", severity: .warning, action: .open(.models))
        #expect(HomeStatus.status(phase: .idle, items: [info]).text == "Ready")
        #expect(HomeStatus.status(phase: .idle, items: [info, warning]).text == "Needs attention")
        #expect(HomeStatus.status(phase: .recording, items: [warning]).text == "Recording")
    }

    @Test
    func suggestionCountReadsNaturally() {
        let one = HomeStatus.attentionItems(HomeStatus.Inputs(glossarySuggestionCount: 1))
        let two = HomeStatus.attentionItems(HomeStatus.Inputs(glossarySuggestionCount: 2))
        #expect(one.map(\.message) == ["1 glossary suggestion is ready to review"])
        #expect(two.map(\.message) == ["2 glossary suggestions are ready to review"])
    }

    @Test
    func destinationNamesWhereTextGoes() {
        #expect(HomeStatus.destination(provider: .appleOnDevice, baseURL: "https://api.openai.com/v1") == nil)
        #expect(HomeStatus.destination(provider: .openAICompatible, baseURL: "https://api.openai.com/v1") == "api.openai.com")
        #expect(HomeStatus.destination(provider: .openAICompatible, baseURL: "http://localhost:11434/v1") == "localhost")
        #expect(HomeStatus.destination(provider: .openAICompatible, baseURL: "") == "Your OpenAI-compatible endpoint")
    }

    @Test
    func navigationOpensAWorkflowAndKeepsItAcrossTabs() {
        let navigation = SettingsNavigation()
        #expect(navigation.selectedTab == .home)
        #expect(navigation.selectedWorkflowID == nil)
        let id = UUID()
        navigation.openWorkflow(id)
        #expect(navigation.selectedTab == .workflows)
        #expect(navigation.selectedWorkflowID == id)
        navigation.selectedTab = .glossary
        navigation.selectedTab = .workflows
        #expect(navigation.selectedWorkflowID == id)
    }

    @Test
    func providerSetupProblemsOpenModels() {
        let items = HomeStatus.attentionItems(HomeStatus.Inputs(providerSetupMessage: "Finish setting up"))
        #expect(items.map(\.action) == [.open(.models)])
    }

    @Test
    func recentColorsFollowWhatTheRunDid() {
        func record(_ transformation: DictationRecord.TransformationSnapshot, provider: TranslationProvider? = .openAICompatible) -> DictationRecord {
            DictationRecord(
                id: UUID(), finishedAt: .now, transcript: "oi", output: "hi",
                transformation: transformation, outcome: .success, provider: provider, duration: 1
            )
        }
        #expect(WorkflowStyle(record(.translation(targetLanguage: "English", toneInstruction: ""))) == .translate)
        #expect(WorkflowStyle(record(.custom(workflowName: "Polish", instruction: "Fix it"))) == .custom)
        #expect(WorkflowStyle(record(.contextual(workflowName: "Summarize", instruction: "Summarize"))) == .custom)
        #expect(WorkflowStyle(record(.contextual(workflowName: "Transcribe", instruction: ""), provider: nil)) == .transcribe)
        #expect(WorkflowStyle(record(.revision(adjustment: "shorter", instruction: "Make it shorter"))) == .revise)
    }

    @Test
    func recentDetailSaysWhereTheResultCameFrom() {
        let transcribed = DictationRecord(
            id: UUID(), finishedAt: .now, transcript: "oi", output: "oi",
            transformation: .contextual(workflowName: "Transcribe", instruction: ""),
            outcome: .success, provider: nil, duration: 0.6
        )
        #expect(HomeSettingsPane.recentDetail(transcribed).contains("on this Mac"))
        #expect(HomeSettingsPane.recentDetail(transcribed).hasSuffix(HomeStatus.durationLabel(0.6)))
    }

    @Test
    func historyFromOlderBuildsDecodesWithoutADuration() throws {
        let record = DictationRecord(
            id: UUID(), finishedAt: .now, transcript: "oi", output: "hi",
            transformation: .contextual(workflowName: "Transcribe", instruction: ""),
            outcome: .success, duration: 0.9
        )
        let encoded = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(DictationRecord.self, from: encoded).duration == 0.9)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["duration"] = nil
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(DictationRecord.self, from: older).duration == nil)
    }
}

@MainActor
struct OnboardingLogicTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suite = testDomainName("SyrupOnboardingTests")
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    @Test
    func aFreshInstallStaysPendingUntilDone() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(OnboardingGate.resolve(defaults))
        #expect(OnboardingGate.isPending(defaults))

        // Quitting midway shows it again, even though creating AppSettings has now written defaults.
        defaults.set("pt-BR", forKey: "dictationLocaleID")
        #expect(OnboardingGate.resolve(defaults))

        OnboardingGate.markDone(defaults)
        #expect(OnboardingGate.resolve(defaults) == false)
        #expect(OnboardingGate.isPending(defaults) == false)
    }

    @Test(arguments: ["workflowListV3", "workflowListV1", "dictationLocaleID", "targetLanguage"])
    func anyExistingSetupSkipsIt(key: String) throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("x", forKey: key)
        #expect(OnboardingGate.resolve(defaults) == false)
        #expect(OnboardingGate.isPending(defaults) == false)
    }

    @Test
    func creatingSettingsCountsAsExistingForTheNextDecision() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        #expect(OnboardingGate.resolve(defaults) == false)
    }

    @Test
    func transcribeSkipsFlavor() {
        let translate = WorkflowKind.translation(targetLanguage: "English", tonePreset: .neutral, customToneText: "")
        #expect(OnboardingStep.steps(for: translate).contains(.flavor))
        #expect(OnboardingStep.steps(for: .transcribeOnly(cleanup: true)).contains(.flavor) == false)
    }

    @Test
    func theRecipeSwitchesBetweenTranslateAndTranscribe() {
        var workflow = Workflow(
            id: UUID(),
            name: "Translate",
            kind: .translation(targetLanguage: "Spanish", tonePreset: .friendly, customToneText: ""),
            dictationLocaleID: "pt-BR",
            translationProvider: nil
        )
        OnboardingRecipe.apply(.language("German"), to: &workflow)
        #expect(workflow.kind == .translation(targetLanguage: "German", tonePreset: .friendly, customToneText: ""))

        OnboardingRecipe.apply(.sameLanguage, to: &workflow)
        #expect(workflow.kind == .transcribeOnly(cleanup: true))
        #expect(workflow.name == "Transcribe")

        OnboardingRecipe.apply(.language("French"), to: &workflow)
        #expect(workflow.kind == .translation(targetLanguage: "French", tonePreset: .neutral, customToneText: ""))
        #expect(workflow.name == "Translate")
    }

    @Test
    func aRenamedWorkflowKeepsItsName() {
        var workflow = Workflow(
            id: UUID(),
            name: "My words",
            kind: .translation(targetLanguage: "Spanish", tonePreset: .neutral, customToneText: ""),
            dictationLocaleID: "pt-BR",
            translationProvider: nil
        )
        OnboardingRecipe.apply(.sameLanguage, to: &workflow)
        #expect(workflow.name == "My words")
    }

    @Test
    func customWorkflowsHaveNoTargetToChange() {
        #expect(OnboardingRecipe.target(of: .custom(instruction: "x", enforceOutputContract: true)) == nil)
    }

    @Test
    func theDictationLanguageComesFromThisMac() {
        let supported = [
            DictationLocaleOption(id: "en-US", displayName: "English"),
            DictationLocaleOption(id: "pt-BR", displayName: "Portuguese (Brazil)"),
            DictationLocaleOption(id: "pt-PT", displayName: "Portuguese (Portugal)"),
        ]
        #expect(OnboardingRecipe.preferredLocale(current: Locale(identifier: "pt_PT"), supported: supported) == "pt-PT")
        #expect(OnboardingRecipe.preferredLocale(current: Locale(identifier: "en_GB"), supported: supported) == "en-US")
        #expect(OnboardingRecipe.preferredLocale(current: Locale(identifier: "ja_JP"), supported: supported) == nil)

        let englishFirstAlphabetically = [DictationLocaleOption(id: "en-AU", displayName: "English (Australia)")] + supported
        #expect(OnboardingRecipe.preferredLocale(current: Locale(identifier: "en_BR"), supported: englishFirstAlphabetically) == "en-US")
    }

    @Test
    func anEnglishSpeakerStartsWithoutTranslatingToEnglish() {
        #expect(OnboardingRecipe.defaultTarget(dictationLocaleID: "en-US", fallback: "English") == .sameLanguage)
        #expect(OnboardingRecipe.defaultTarget(dictationLocaleID: "pt-BR", fallback: "English") == .language("English"))
        #expect(OnboardingRecipe.defaultTarget(dictationLocaleID: "en-US", fallback: "Spanish") == .language("Spanish"))
    }
}
