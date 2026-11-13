import SwiftUI

/// Bindings into one saved workflow, shared by the workflow editor and the workflow sentence.
@MainActor
struct WorkflowBindings {
    let settings: AppSettings
    let workflowID: UUID
    let assetManager: TranscriberAssetManager
    let speechModels: SpeechModelCatalog

    enum KindOption: String, CaseIterable, Identifiable {
        case translation
        case custom
        case transcribeOnly

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .translation:
                "Translate"
            case .custom:
                "Custom instruction"
            case .transcribeOnly:
                "Transcribe"
            }
        }
    }

    var workflow: Workflow {
        settings.workflowList.workflows.first { $0.id == workflowID } ?? settings.activeWorkflow
    }

    var isActive: Bool {
        workflow.id == settings.workflowList.activeWorkflowID
    }

    func update(_ change: (inout Workflow) -> Void) {
        settings.updateWorkflow(id: workflow.id, change)
    }

    // MARK: Input

    var input: Binding<WorkflowInput> {
        Binding { workflow.input } set: { input in update { $0.input = input } }
    }

    var includeSelectionContext: Binding<Bool> {
        Binding { workflow.includeSelectionContext } set: { isOn in update { $0.includeSelectionContext = isOn } }
    }

    var dictationLocale: Binding<String> {
        Binding {
            workflow.dictationLocaleID
        } set: { localeID in
            update { $0.dictationLocaleID = localeID }
            assetManager.prepareSelectedLocale(localeID)
        }
    }

    var speechEngine: Binding<SpeechEngine> {
        Binding {
            workflow.speechEngine
        } set: { engine in
            update { $0.speechEngine = engine }
            speechModels.manager(for: engine)?.loadIfDownloaded()
        }
    }

    /// Speech models that can run this workflow's language on this Mac.
    var availableSpeechEngines: [SpeechEngine] {
        SpeechEngine.allCases.filter { engine in
            engine.supports(localeID: workflow.dictationLocaleID)
                && (engine == .apple || speechModels.manager(for: engine)?.state != .unsupported)
        }
    }

    var localeIsMissing: Bool {
        assetManager.supportedLocales.contains { $0.id == workflow.dictationLocaleID } == false
    }

    var localeName: String {
        TranscriberAssetManager.displayName(for: Locale(identifier: workflow.dictationLocaleID))
    }

    var dictationLocaleChoices: [MenuChoice<String>] {
        (localeIsMissing ? [MenuChoice(value: workflow.dictationLocaleID, title: localeName)] : [])
            + assetManager.supportedLocales.map { MenuChoice(value: $0.id, title: $0.displayName) }
    }

    @ViewBuilder
    var dictationLocaleOptions: some View {
        if localeIsMissing {
            Text(localeName)
                .tag(workflow.dictationLocaleID)
        }
        ForEach(assetManager.supportedLocales) { locale in
            Text(locale.displayName)
                .tag(locale.id)
        }
    }

    // MARK: Output

    var kind: Binding<KindOption> {
        Binding {
            switch workflow.kind {
            case .translation: .translation
            case .custom: .custom
            case .transcribeOnly: .transcribeOnly
            }
        } set: { option in
            update { workflow in
                switch option {
                case .translation:
                    workflow.kind = .translation(
                        targetLanguage: settings.targetLanguage,
                        tonePreset: settings.tonePreset,
                        customToneText: settings.customToneText
                    )
                case .custom:
                    workflow.kind = .custom(instruction: "", enforceOutputContract: true)
                case .transcribeOnly:
                    workflow.kind = .transcribeOnly(cleanup: true)
                }
            }
        }
    }

    var targetLanguage: Binding<String> {
        Binding {
            guard case .translation(let targetLanguage, _, _) = workflow.kind else { return "" }
            return targetLanguage
        } set: { targetLanguage in
            update { workflow in
                guard case .translation(_, let tone, let customTone) = workflow.kind else { return }
                workflow.kind = .translation(targetLanguage: targetLanguage, tonePreset: tone, customToneText: customTone)
            }
        }
    }

    var tonePreset: Binding<TonePreset> {
        Binding {
            guard case .translation(_, let tone, _) = workflow.kind else { return .neutral }
            return tone
        } set: { tone in
            update { workflow in
                guard case .translation(let language, _, let customTone) = workflow.kind else { return }
                workflow.kind = .translation(targetLanguage: language, tonePreset: tone, customToneText: customTone)
            }
        }
    }

    var customToneText: Binding<String> {
        Binding {
            guard case .translation(_, _, let customTone) = workflow.kind else { return "" }
            return customTone
        } set: { customTone in
            update { workflow in
                guard case .translation(let language, let tone, _) = workflow.kind else { return }
                workflow.kind = .translation(targetLanguage: language, tonePreset: tone, customToneText: customTone)
            }
        }
    }

    var customInstruction: Binding<String> {
        Binding {
            guard case .custom(let instruction, _) = workflow.kind else { return "" }
            return instruction
        } set: { instruction in
            update { workflow in
                guard case .custom(_, let enforce) = workflow.kind else { return }
                workflow.kind = .custom(instruction: instruction, enforceOutputContract: enforce)
            }
        }
    }

    var outputContract: Binding<Bool> {
        Binding {
            guard case .custom(_, let enforce) = workflow.kind else { return true }
            return enforce
        } set: { enforce in
            update { workflow in
                guard case .custom(let instruction, _) = workflow.kind else { return }
                workflow.kind = .custom(instruction: instruction, enforceOutputContract: enforce)
            }
        }
    }

    var cleanup: Binding<Bool> {
        Binding {
            guard case .transcribeOnly(let cleanup, _) = workflow.kind else { return true }
            return cleanup
        } set: { cleanup in
            update {
                guard case .transcribeOnly(_, let symbols) = $0.kind else { return }
                $0.kind = .transcribeOnly(cleanup: cleanup, spokenSymbols: symbols)
            }
        }
    }

    var spokenSymbols: Binding<Bool> {
        Binding {
            guard case .transcribeOnly(_, let symbols) = workflow.kind else { return false }
            return symbols
        } set: { symbols in
            update {
                guard case .transcribeOnly(let cleanup, _) = $0.kind else { return }
                $0.kind = .transcribeOnly(cleanup: cleanup, spokenSymbols: symbols)
            }
        }
    }

    /// Empty string means the default provider.
    var providerOverride: Binding<String> {
        Binding {
            workflow.translationProvider?.rawValue ?? ""
        } set: { rawValue in
            update { $0.translationProvider = rawValue.isEmpty ? nil : TranslationProvider(rawValue: rawValue) }
        }
    }

    var effectiveProvider: TranslationProvider {
        workflow.translationProvider ?? settings.translationProvider
    }

    var providerChoices: [MenuChoice<String>] {
        [MenuChoice(value: "", title: "Default (\(settings.translationProvider.displayName))")]
            + TranslationProvider.allCases.enumerated().map { index, provider in
                MenuChoice(value: provider.rawValue, title: provider.displayName, startsGroup: index == 0)
            }
    }

    @ViewBuilder
    var providerOptions: some View {
        Text("Default (\(settings.translationProvider.displayName))")
            .tag("")
        Divider()
        ForEach(TranslationProvider.allCases) { provider in
            Text(provider.displayName)
                .tag(provider.rawValue)
        }
    }

    // MARK: Delivery (shared by every workflow)

    var pastesResult: Binding<Bool> {
        Binding { settings.autoPasteEnabled } set: { settings.autoPasteEnabled = $0 }
    }

    static let targetLanguages = ActiveWorkflowBindings.targetLanguages

    var targetLanguageChoices: [MenuChoice<String>] {
        let current = targetLanguage.wrappedValue
        let custom = Self.targetLanguages.contains(current) == false && current.isEmpty == false
        return (custom ? [MenuChoice(value: current, title: current)] : [])
            + Self.targetLanguages.map { MenuChoice(value: $0, title: $0) }
    }
}
