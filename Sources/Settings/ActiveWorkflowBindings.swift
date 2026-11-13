import SwiftUI

/// Quick controls for the active workflow, shared by the menu bar and Home.
@MainActor
struct ActiveWorkflowBindings {
    let state: AppState

    static let targetLanguages = [
        "English",
        "Portuguese",
        "Portuguese (Brazil)",
        "Spanish",
        "French",
        "German",
        "Italian",
        "Japanese",
    ]

    private static let menuTonePresets = TonePreset.allCases.filter { $0 != .custom }

    var workflow: Binding<UUID> {
        Binding {
            state.settings.workflowList.activeWorkflowID
        } set: { id in
            state.settings.setActiveWorkflowID(id)
            state.transcriberAssetManager.prepareSelectedLocale(state.settings.activeWorkflow.dictationLocaleID)
            state.refreshWorkflowHotkeys()
        }
    }

    var dictationLocale: Binding<String> {
        Binding {
            state.settings.activeWorkflow.dictationLocaleID
        } set: { newLocaleID in
            state.settings.updateWorkflow(id: state.settings.activeWorkflow.id) { workflow in
                workflow.dictationLocaleID = newLocaleID
            }
            state.transcriberAssetManager.prepareSelectedLocale(newLocaleID)
        }
    }

    var targetLanguage: Binding<String> {
        Binding {
            activeTargetLanguage
        } set: { newLanguage in
            state.settings.updateWorkflow(id: state.settings.activeWorkflow.id) { workflow in
                guard case .translation(_, let tonePreset, let customToneText) = workflow.kind else { return }
                workflow.kind = .translation(
                    targetLanguage: newLanguage,
                    tonePreset: tonePreset,
                    customToneText: customToneText
                )
            }
        }
    }

    var toneInstruction: Binding<String> {
        Binding {
            activeToneInstruction
        } set: { newInstruction in
            state.settings.updateWorkflow(id: state.settings.activeWorkflow.id) { workflow in
                guard case .translation(let targetLanguage, _, _) = workflow.kind else { return }
                if let preset = TonePreset.allCases.first(where: {
                    $0 != .custom && $0.instruction() == newInstruction
                }) {
                    workflow.kind = .translation(
                        targetLanguage: targetLanguage,
                        tonePreset: preset,
                        customToneText: ""
                    )
                } else {
                    workflow.kind = .translation(
                        targetLanguage: targetLanguage,
                        tonePreset: newInstruction.isEmpty ? .neutral : .custom,
                        customToneText: newInstruction
                    )
                }
            }
        }
    }

    @ViewBuilder
    var workflowOptions: some View {
        ForEach(state.settings.workflowList.workflows) { workflow in
            Text(workflow.name)
                .tag(workflow.id)
        }
    }

    var dictationLocaleChoices: [MenuChoice<String>] {
        (selectedLocaleIsMissing
            ? [MenuChoice(value: state.settings.activeWorkflow.dictationLocaleID, title: selectedLocaleName)]
            : [])
            + state.transcriberAssetManager.supportedLocales.map { MenuChoice(value: $0.id, title: $0.displayName) }
    }

    @ViewBuilder
    var dictationLocaleOptions: some View {
        if selectedLocaleIsMissing {
            Text(selectedLocaleName)
                .tag(state.settings.activeWorkflow.dictationLocaleID)
        }

        ForEach(state.transcriberAssetManager.supportedLocales) { locale in
            Text(locale.displayName)
                .tag(locale.id)
        }
    }

    @ViewBuilder
    var targetLanguageOptions: some View {
        if targetLanguageIsCustom {
            Text(activeTargetLanguage)
                .tag(activeTargetLanguage)
        }

        ForEach(Self.targetLanguages, id: \.self) { language in
            Text(language)
                .tag(language)
        }
    }

    @ViewBuilder
    var toneOptions: some View {
        if toneInstructionIsCustom {
            Text("Custom")
                .tag(activeToneInstruction)
        }

        ForEach(Self.menuTonePresets) { preset in
            Text(preset.displayName)
                .tag(preset.instruction())
        }
    }

    private var selectedLocaleIsMissing: Bool {
        state.transcriberAssetManager.supportedLocales.isEmpty
            || state.transcriberAssetManager.supportedLocales.contains { $0.id == state.settings.activeWorkflow.dictationLocaleID } == false
    }

    private var selectedLocaleName: String {
        TranscriberAssetManager.displayName(for: Locale(identifier: state.settings.activeWorkflow.dictationLocaleID))
    }

    private var targetLanguageIsCustom: Bool {
        Self.targetLanguages.contains(activeTargetLanguage) == false
    }

    private var toneInstructionIsCustom: Bool {
        Self.menuTonePresets.contains { $0.instruction() == activeToneInstruction } == false
    }

    private var activeTargetLanguage: String {
        guard case .translation(let targetLanguage, _, _) = state.settings.activeWorkflow.kind else {
            return ""
        }
        return targetLanguage
    }

    private var activeToneInstruction: String {
        guard case .translation(_, let tonePreset, let customToneText) = state.settings.activeWorkflow.kind else {
            return ""
        }
        return tonePreset.instruction(customText: customToneText)
    }
}
