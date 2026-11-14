import Foundation
import Testing
@testable import Syrup

@MainActor
struct EarlyTransformationNoteTests {
    private let translate = WorkflowKind.translation(targetLanguage: "English", tonePreset: .neutral, customToneText: "")

    private func workflow(
        _ name: String,
        provider: TranslationProvider? = nil,
        engine: SpeechEngine = .apple,
        input: WorkflowInput = .voice,
        kind: WorkflowKind? = nil
    ) -> Workflow {
        Workflow(
            id: UUID(),
            name: name,
            kind: kind ?? translate,
            dictationLocaleID: "pt-BR",
            translationProvider: provider,
            input: input,
            speechEngine: engine
        )
    }

    private let cue = "This feature only works with Apple On-Device models or a server on this Mac."
    private let cloudURL = "https://api.openai.com/v1"

    private func note(_ provider: TranslationProvider, _ baseURL: String, _ workflows: [Workflow]) -> EarlyTransformationNote {
        EarlyTransformationNote.make(provider: provider, baseURL: baseURL, workflows: workflows)
    }

    private func note(_ provider: TranslationProvider, _ workflows: [Workflow]) -> EarlyTransformationNote {
        note(provider, "", workflows)
    }

    @Test
    func providerDecidesWhetherTheToggleIsAvailable() {
        let plain = [workflow("Translate"), workflow("Polish")]
        let apple = note(.appleOnDevice, plain)
        #expect(apple == EarlyTransformationNote(isAvailable: true, message: "Works for all your voice workflows.", detail: nil))
        #expect(note(.appleOnDevice, [workflow("Translate")]).message == "Works for your voice workflow.")

        #expect(note(.openAICompatible, " http://localhost:11434/v1 ", plain).isAvailable)
        #expect(note(.openAICompatible, "http://127.0.0.1:1234/v1", plain).isAvailable)
        #expect(note(.openAICompatible, "http://[::1]:1234/v1", plain).isAvailable)

        // Off this Mac, or no usable address: disabled with the one cue and nothing else.
        for (provider, baseURL) in [
            (TranslationProvider.openAICompatible, cloudURL),
            (.openAICompatible, "http://192.0.2.20:11434/v1"),
            (.openAICompatible, ""),
            (.openAICompatible, "localhost:11434"),
            (.codexCLI, "http://localhost:11434/v1"),
        ] {
            #expect(note(provider, baseURL, plain) == EarlyTransformationNote(isAvailable: false, message: cue, detail: nil))
        }
    }

    @Test
    func transcribeAndSelectionWorkflowsAreNotCounted() {
        let ignored = [
            workflow("Translate"),
            workflow("Transcribe", kind: .transcribeOnly(cleanup: true)),
            workflow("Summarize Selection", input: .selection),
        ]
        #expect(note(.appleOnDevice, ignored) == EarlyTransformationNote(isAvailable: true, message: "Works for your voice workflow.", detail: nil))

        let none = Array(ignored.dropFirst())
        let unavailable = note(.appleOnDevice, none)
        #expect(unavailable.isAvailable == false)
        #expect(unavailable.message == cue)
        #expect(unavailable.detail == "It also needs a voice workflow other than Transcribe.")
        #expect(note(.appleOnDevice, []).isAvailable == false)
    }

    @Test
    func speechModelGetsASecondLineOnlyWhenItIsTheBlocker() {
        let parakeet = note(.appleOnDevice, [workflow("Notes", engine: .parakeetUltra)])
        #expect(parakeet == EarlyTransformationNote(
            isAvailable: false,
            message: cue,
            detail: "It also needs the Apple speech model. Notes uses Parakeet Ultra."
        ))
        #expect(parakeet.spokenReason == "\(cue) It also needs the Apple speech model. Notes uses Parakeet Ultra.")

        let two = note(.appleOnDevice, [workflow("A", engine: .parakeetUltra), workflow("B", engine: .nemotronStreaming)])
        #expect(two.detail == "It also needs the Apple speech model. 2 voice workflows use downloaded models.")

        // Cloud provider and a downloaded model: the provider is in the way, so the cue says it all.
        #expect(note(.openAICompatible, cloudURL, [workflow("Notes", engine: .parakeetUltra)]).detail == nil)
        // A downloaded model on a workflow that also picks Codex CLI: the provider still blocks it.
        #expect(note(.appleOnDevice, [workflow("Notes", provider: .codexCLI, engine: .parakeetUltra)]).detail == nil)

        // One blocked by speech, one by provider: only the speech one is named.
        let mixed = note(.appleOnDevice, [workflow("Notes", engine: .parakeetRedux), workflow("Cloud", provider: .codexCLI)])
        #expect(mixed.detail == "It also needs the Apple speech model. Notes uses Parakeet Redux.")
    }

    @Test
    func availableNoteNamesWhatItReachesAndSkips() {
        let mixed = [workflow("Translate"), workflow("Notes", engine: .parakeetUltra), workflow("Cloud", provider: .codexCLI)]
        #expect(note(.appleOnDevice, mixed) == EarlyTransformationNote(
            isAvailable: true,
            message: "Works for Translate.",
            detail: "Not for the other 2, which use a downloaded speech model or a provider that isn't on this Mac."
        ))

        #expect(note(.appleOnDevice, [workflow("Translate"), workflow("Polish"), workflow("Notes", engine: .parakeetRedux)])
            == EarlyTransformationNote(isAvailable: true, message: "Works for Translate and Polish.", detail: "Not for Notes, which uses Parakeet Redux."))

        // A workflow that picks Apple On-Device keeps the toggle usable with a cloud default.
        let override = note(.openAICompatible, cloudURL, [workflow("Translate"), workflow("Private", provider: .appleOnDevice)])
        #expect(override == EarlyTransformationNote(
            isAvailable: true,
            message: "Works for Private.",
            detail: "Not for Translate, which uses a provider that isn't on this Mac."
        ))
        #expect(note(.codexCLI, [workflow("Private", provider: .appleOnDevice)]).message == "Works for your voice workflow.")

        let both = note(.appleOnDevice, [workflow("Translate"), workflow("Far", provider: .codexCLI, engine: .parakeetUltra)])
        #expect(both.detail == "Not for Far, which uses Parakeet Ultra and a provider that isn't on this Mac.")

        let many = (1...4).map { workflow("W\($0)") } + [workflow("Cloud A", provider: .codexCLI), workflow("Cloud B", provider: .codexCLI)]
        let counted = note(.appleOnDevice, many)
        #expect(counted.message == "Works for 4 of 6 voice workflows.")
        #expect(counted.detail == "Not for the other 2, which use a provider that isn't on this Mac.")
    }

    @Test
    func overridesUseTheGlobalEndpoint() {
        // A workflow can pick OpenAI-compatible, but the server address is the one in Models.
        let pick = [workflow("Local", provider: .openAICompatible)]
        #expect(note(.appleOnDevice, "http://localhost:1234/v1", pick).isAvailable)
        #expect(note(.appleOnDevice, "https://api.example.com/v1", pick)
            == EarlyTransformationNote(isAvailable: false, message: cue, detail: nil))
    }
}

@MainActor
struct CaretFitRowTests {
    @Test
    func needsAccessibilityAndNotPaste() {
        #expect(CaretFitRow.isAvailable(.granted))
        for status in [PermissionStatusModel.Status.notRequested, .denied, .restricted, .unknown] {
            #expect(CaretFitRow.isAvailable(status) == false)
        }
        #expect(CaretFitRow.accessibilityCue == "Needs Accessibility to read the text around the cursor.")
        #expect(CaretFitRow.detail.contains("copies and pastes"))
    }
}

@MainActor
struct MishearingCheckCopyTests {
    private let english = Locale(identifier: "en_US")

    private func result(
        _ forms: [String],
        everyday: [String] = [],
        samples: Int = 2,
        exact: Int = 0,
        unavailable: [MishearingProbeLocaleIssue] = []
    ) -> MishearingProbeResult {
        var result = MishearingProbeResult(
            heardForms: forms,
            sampleCount: samples,
            exactMatchCount: exact,
            discardedSampleCount: 0,
            failedSampleCount: 0,
            unavailableLocales: unavailable
        )
        result.everydayForms = everyday
        return result
    }

    @Test
    func statusLineCoversEveryState() {
        typealias Status = MishearingCheckCopy.Status
        #expect(MishearingCheckCopy.status(for: .idle) == nil)
        #expect(MishearingCheckCopy.status(for: .running) == .checking)
        #expect(MishearingCheckCopy.status(for: .results(result(["Graffana"]))) == .heard(["Graffana"]))
        #expect(MishearingCheckCopy.status(for: .results(result([]))) == .noNewSuggestions)
        #expect(MishearingCheckCopy.status(for: .recognizedCorrectly(result([], exact: 2))) == .heardCorrectly)
        #expect(MishearingCheckCopy.status(for: .failed(.timedOut)) == .failed("Check took too long"))
        #expect(MishearingCheckCopy.status(for: .failed(.noUsableSamples)) == .failed("No clear result"))

        let noVoice = MishearingProbeLocaleIssue(localeID: "pt-BR", reason: .noVoice)
        let model = MishearingProbeLocaleIssue(localeID: "en-US", reason: .speechModelNotInstalled)
        #expect(MishearingCheckCopy.status(for: .unavailable([noVoice]), locale: english)
            == .notChecked("Couldn't check: no Portuguese (Brazil) voice"))
        #expect(MishearingCheckCopy.status(for: .unavailable([noVoice, model]), locale: english)
            == .notChecked("Couldn't check: no Portuguese (Brazil) voice, and more"))
    }

    @Test
    func tableTextIsShortAndDetailCarriesTheReason() {
        #expect(MishearingCheckCopy.text(for: .checking) == "Checking…")
        #expect(MishearingCheckCopy.text(for: .heard(["Graffana"])) == "1 suggestion")
        #expect(MishearingCheckCopy.text(for: .heard(["Graffana", "profile"])) == "2 suggestions")
        #expect(MishearingCheckCopy.text(for: .noNewSuggestions) == "Nothing new")
        #expect(MishearingCheckCopy.text(for: .heardCorrectly) == "Heard correctly")
        #expect(MishearingCheckCopy.text(for: .notChecked("Couldn't check: no Portuguese (Brazil) voice")) == "Not checked")
        #expect(MishearingCheckCopy.detail(for: .notChecked("Couldn't check: no Portuguese (Brazil) voice"))
            == "Couldn't check: no Portuguese (Brazil) voice")
        #expect(MishearingCheckCopy.text(for: .failed("Check took too long")) == "Check failed")
        #expect(MishearingCheckCopy.detail(for: .failed("Check took too long")) == "Check took too long")
        #expect(MishearingCheckCopy.detail(for: .heardCorrectly) == nil)
    }

    @Test
    func issuesAreListedOnceWithTheirFix() {
        let noVoice = MishearingProbeLocaleIssue(localeID: "pt-BR", reason: .noVoice)
        let permissionPT = MishearingProbeLocaleIssue(localeID: "pt-BR", reason: .speechPermissionRequired)
        let permissionEN = MishearingProbeLocaleIssue(localeID: "en-US", reason: .speechPermissionRequired)
        let states: [MishearingCheckCopy.TermState] = [
            .unavailable([noVoice, permissionPT]),
            .unavailable([noVoice, permissionEN]),
            .results(result(["Graffana"], unavailable: [noVoice])),
            .recognizedCorrectly(result([], exact: 2)),
            .idle,
        ]
        #expect(MishearingCheckCopy.issues(in: states) == [noVoice, permissionPT])

        #expect(MishearingCheckCopy.issueText(noVoice, locale: english)
            == "No system voice for Portuguese (Brazil). Add one in System Settings > Accessibility > Spoken Content.")
        #expect(MishearingCheckCopy.fix(for: noVoice) == .openSpokenContent)
        #expect(MishearingCheckCopy.fix(for: permissionPT) == .openPrivacy)
        let model = MishearingProbeLocaleIssue(localeID: "en-US", reason: .speechModelNotInstalled)
        #expect(MishearingCheckCopy.fix(for: model) == .openWorkflow(localeID: "en-US"))
        #expect(MishearingCheckCopy.issueText(model, locale: english)
            == "The English (United States) speech model isn't installed. Open a workflow that dictates in English (United States) to download it.")
        #expect(MishearingCheckCopy.fix(for: MishearingProbeLocaleIssue(localeID: "xx", reason: .unsupportedLocale)) == MishearingCheckCopy.Fix.none)
    }

    @Test
    func summaryCountsOnlyWhatWasChecked() {
        #expect(MishearingCheckCopy.summary(of: [.idle, .running]) == nil)
        let states: [MishearingCheckCopy.TermState] = [
            .results(result(["Graffana"])),
            .results(result([])),
            .recognizedCorrectly(result([], exact: 2)),
            .recognizedCorrectly(result([], exact: 2)),
            .unavailable([]),
            .failed(.synthesisFailed),
        ]
        #expect(MishearingCheckCopy.summary(of: states) == "1 with suggestions, 2 heard correctly, 2 not checked")
    }

    @Test
    func descriptionNamesTheLanguagesAndBlockedStates() {
        #expect(MishearingCheckCopy.description(localeIDs: ["en-US", "pt-BR"], isForegroundActive: false, locale: english)
            == "A system voice says each term in English (United States) and Portuguese (Brazil), and dictation writes down what it hears.")
        #expect(MishearingCheckCopy.languageList(["en-US", "pt-BR", "es-ES"], locale: english)
            == "English (United States), Portuguese (Brazil), and Spanish (Spain)")
        #expect(MishearingCheckCopy.description(localeIDs: [], isForegroundActive: false)
            == "Needs a voice workflow. Its dictation language is the one checked.")
        #expect(MishearingCheckCopy.description(localeIDs: ["en-US"], isForegroundActive: true)
            == "Not while you dictate. Check again when it's done.")
        #expect(MishearingCheckCopy.progressText(.init(done: 3, total: 12)) == "3 of 12")
        #expect(MishearingCheckCopy.progressText(.init(done: 0, total: 1)) == "Checking 1 term…")
    }

    @Test
    func everydayFormsAreLabeledAndConfirmed() {
        #expect(MishearingCheckCopy.addLabel(form: "those", term: "OAuth", isEveryday: true)
            == "Add everyday words “those” as a sounds-like for OAuth")
        #expect(MishearingCheckCopy.addLabel(form: "Graffana", term: "Grafana", isEveryday: false)
            == "Add “Graffana” as a sounds-like for Grafana")
        let copy = MishearingCheckCopy.everydayConfirmation(form: "those", term: "OAuth")
        #expect(copy.message == "Add “those” as a sounds-like for OAuth?")
        #expect(copy.detail.contains("ordinary sentences"))
    }
}
