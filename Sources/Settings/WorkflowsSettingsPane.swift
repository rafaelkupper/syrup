import KeyboardShortcuts
import SwiftUI

struct WorkflowsSettingsPane: View {
    @Bindable var settings: AppSettings
    @Bindable var assetManager: TranscriberAssetManager
    let speechModels: SpeechModelCatalog
    @Bindable var navigation: SettingsNavigation
    let onPasteEnabled: () -> Void
    let shortcutChangeHandler: () -> Void

    private static let listWidth: CGFloat = 240

    var body: some View {
        // The editor's scroll view spans the whole pane so the toolbar above it lights up as one
        // piece, like every other tab. Its content starts right of the list, which sits on top.
        WorkflowEditorView(
            workflowID: selectedWorkflow.id,
            settings: settings,
            assetManager: assetManager,
            speechModels: speechModels,
            onPasteEnabled: onPasteEnabled,
            shortcutChangeHandler: shortcutChangeHandler
        )
        .id(selectedWorkflow.id)
        .contentMargins(.leading, Self.listWidth, for: .scrollContent)
        .overlay(alignment: .leading) {
            HStack(spacing: 0) {
                listColumn
                    .frame(width: Self.listWidth)
                Divider()
            }
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            // Keeps the list's own scroll view from reaching under the toolbar, where it
            // would light up separately from the editor's.
            Color.clear.frame(height: 1)
            List(selection: selection) {
                ForEach(settings.workflowList.workflows) { workflow in
                    row(workflow)
                        .tag(workflow.id)
                        .contextMenu { actions(for: workflow) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)

            Divider()
            listBar
        }
    }

    private func row(_ workflow: Workflow) -> some View {
        HStack(spacing: 9) {
            WorkflowTile(style: WorkflowStyle(workflow.kind), size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(workflow.name.isEmpty ? "Untitled" : workflow.name)
                    .lineLimit(1)
                Text(subtitle(workflow))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if workflow.id == settings.workflowList.activeWorkflowID {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .help("Active: Dictate runs it unless an app is set to another workflow")
                    .accessibilityLabel("Active")
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ workflow: Workflow) -> String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .dictateWorkflow(workflow.id)) else {
            return workflow.summary
        }
        return "\(shortcut.description) · \(workflow.summary)"
    }

    private var listBar: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(WorkflowTemplate.templates(
                    targetLanguage: settings.targetLanguage,
                    tonePreset: settings.tonePreset,
                    customToneText: settings.customToneText
                )) { template in
                    Button(template.name) {
                        navigation.selectedWorkflowID = settings.addWorkflow(from: template)
                        shortcutChangeHandler()
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 22, height: 18)
            }
            .menuIndicator(.hidden)
            .help("New workflow from a template")
            .accessibilityLabel("New Workflow")

            Button {
                delete(selectedWorkflow)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 22, height: 18)
            }
            .disabled(settings.workflowList.workflows.count == 1)
            .help("Delete workflow")
            .accessibilityLabel("Delete Workflow")

            Spacer()

            Menu {
                actions(for: selectedWorkflow)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 22, height: 18)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More")
        }
        .buttonStyle(.borderless)
        .menuStyle(.button)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func actions(for workflow: Workflow) -> some View {
        Button("Make Active") {
            settings.setActiveWorkflowID(workflow.id)
            shortcutChangeHandler()
        }
        .disabled(workflow.id == settings.workflowList.activeWorkflowID)

        Button("Duplicate") {
            if let id = settings.duplicateWorkflow(id: workflow.id) {
                navigation.selectedWorkflowID = id
            }
        }

        Divider()

        Button("Delete…", role: .destructive) {
            delete(workflow)
        }
        .disabled(settings.workflowList.workflows.count == 1)
    }

    private func delete(_ workflow: Workflow) {
        guard settings.workflowList.workflows.count > 1,
              confirmDestructiveAction(
                  message: "Delete “\(workflow.name)”?",
                  detail: "Apps assigned to it go back to the active workflow, and its shortcut stops working. This can't be undone.",
                  confirmTitle: "Delete Workflow"
              ) else { return }
        settings.deleteWorkflow(id: workflow.id)
        navigation.selectedWorkflowID = nil
        shortcutChangeHandler()
    }

    private var selectedWorkflow: Workflow {
        settings.workflowList.workflows.first { $0.id == navigation.selectedWorkflowID } ?? settings.activeWorkflow
    }

    private var selection: Binding<UUID?> {
        Binding {
            selectedWorkflow.id
        } set: { id in
            if let id { navigation.selectedWorkflowID = id }
        }
    }
}
