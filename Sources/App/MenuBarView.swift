import AppKit
import KeyboardShortcuts
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openSettings) private var openSettings
    let updates: UpdateController
    let state: AppState
    let settingsNavigation: SettingsNavigation

    var body: some View {
        Text(statusText)

        Picker("Workflow", selection: controls.workflow) { controls.workflowOptions }

        if case .translation = state.settings.activeWorkflow.kind {
            Picker("Dictation", selection: controls.dictationLocale) { controls.dictationLocaleOptions }
            Picker("Target", selection: controls.targetLanguage) { controls.targetLanguageOptions }
            Picker("Tone", selection: controls.toneInstruction) { controls.toneOptions }
        }

        Toggle("Pause Shortcuts", isOn: pauseHotkeyBinding)

        if state.canCopyPendingResult {
            Button("Copy result again") {
                state.copyPendingResult()
            }
        }

        Button("Copy last result") {
            state.copyLastResult()
        }
        .disabled(state.canCopyLastResult == false)

        Button("Paste last result") {
            Task { await state.pasteLastResult() }
        }
        .globalKeyboardShortcut(.pasteLast)
        .disabled(!state.canCopyLastResult)

        Button(state.revisionMenuActionTitle, action: state.performRevisionMenuAction)
            .globalKeyboardShortcut(.revise)
            .disabled(state.canPerformRevisionMenuAction == false)

        if state.canCopyTranscriptFallback {
            Button("Copy transcript instead") {
                state.copyTranscriptFallback()
            }
        }

        if state.history.records.isEmpty == false {
            Divider()
            Text("Recent")
            ForEach(Array(state.history.records.prefix(5))) { record in
                if record.canCopyFromHistory {
                    Button(Self.recordTitle(for: record)) {
                        state.copyHistoryRecord(recordID: record.id)
                    }
                    .disabled(state.pipelineState.isActive)
                } else {
                    Text(Self.recordTitle(for: record))
                }

                if record.canRetry {
                    if record.canRetryWithOriginalProvider {
                        Button("Retry \(record.transformation.displayName)") {
                            state.retryTranslation(recordID: record.id)
                        }
                        .disabled(state.pipelineState.isActive)
                    }
                    Menu(record.provider == nil ? "Retry with provider" : "Retry with another provider") {
                        ForEach(state.settings.offeredProviders().filter { $0 != record.provider }) { provider in
                            Button(provider.displayName) {
                                state.retryTranslation(recordID: record.id, using: provider)
                            }
                        }
                    }
                    .disabled(state.pipelineState.isActive)
                }
            }

            Button("Clear History…") {
                let count = state.history.records.count
                guard confirmDestructiveAction(
                    message: count == 1 ? "Clear 1 result from History?" : "Clear \(count) results from History?",
                    detail: "This can't be undone.",
                    confirmTitle: "Clear History"
                ) else { return }
                Task { await state.history.clear() }
            }
        }

        if let message = state.history.persistenceError { Text(message) }
        Divider()
        Button("Add Glossary Term…", action: openGlossary)
        Button("Open Syrup…", action: openSyrupWindow)
            .keyboardShortcut(",")
        Button(updates.updateAvailable ? "Update available…" : "Check for Updates…") {
            updates.checkForUpdates()
        }
        .disabled(!updates.canCheckForUpdates)
        Button("Quit") {
            // The app delegate flushes history and restores volume on every quit path.
            NSApplication.shared.terminate(nil)
        }
    }

    private var controls: ActiveWorkflowBindings { ActiveWorkflowBindings(state: state) }

    private var statusText: String {
        if state.isHotkeyPaused, state.pipelineState == .idle {
            return "Paused"
        }

        return switch state.pipelineState {
        case .idle:
            "Ready"
        case .recording:
            "Recording"
        case .transcribing:
            "Transcribing"
        case .translating:
            "Translating"
        case .error(let message):
            message
        }
    }

    private func openGlossary() {
        settingsNavigation.openGlossary(draftTerm: Self.glossaryDraftFromClipboard())
        openSyrupWindow()
    }

    private func openSyrupWindow() {
        NSApp.activate()
        openSettings()
    }

    private static func glossaryDraftFromClipboard() -> String {
        guard let clipboardText = NSPasteboard.general.string(forType: .string) else {
            return ""
        }

        let trimmedText = clipboardText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false,
              trimmedText.count <= 60,
              trimmedText.rangeOfCharacter(from: .newlines) == nil else {
            return ""
        }

        return trimmedText
    }

    private var pauseHotkeyBinding: Binding<Bool> {
        Binding {
            state.isHotkeyPaused
        } set: { isPaused in
            state.isHotkeyPaused = isPaused
        }
    }

    private static func recordTitle(for record: DictationRecord) -> String {
        let marker: String
        if case .failed = record.outcome {
            marker = "Failed: "
        } else {
            marker = ""
        }

        let title: String
        let revisionMarker: String
        if case .revision(let adjustment, _) = record.transformation {
            title = adjustment
            revisionMarker = "↻ "
        } else {
            title = record.output ?? record.transcript
            revisionMarker = ""
        }

        let text = title.replacing("\n", with: " ")
        let prefix = text.count > 40 ? "\(text.prefix(40))..." : text
        return "\(marker)\(revisionMarker)\(prefix)"
    }
}

extension AppState.PipelineState {
    var isActive: Bool {
        switch self {
        case .recording, .transcribing, .translating:
            true
        case .idle, .error:
            false
        }
    }
}
