import SwiftUI

/// What happens to a result.
struct DeliverySettingsPane: View {
    @Bindable var settings: AppSettings
    let autoPaster: any AutoPasting
    let permissions: PermissionStatusModel
    let navigation: SettingsNavigation
    let onPermissionAction: () -> Void

    var body: some View {
        Form {
            Section {
                route
            }
            resultSection
            soundSection
        }
        .formStyle(.grouped)
    }

    private var pastes: Bool {
        settings.autoPasteEnabled && permissions.accessibility == .granted
    }

    /// Where a result goes, in one line.
    private var route: some View {
        HStack(spacing: 10) {
            Label("Clipboard, always", systemImage: "doc.on.clipboard")
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            if pastes {
                Label(
                    settings.pinDeliveryTarget ? "Pasted into the editor you started in" : "Pasted into the app in front",
                    systemImage: "text.insert"
                )
            } else {
                Label(
                    settings.autoPasteEnabled ? "Not pasted until Accessibility is allowed" : "Not pasted. Press ⌘V yourself.",
                    systemImage: "text.insert"
                )
                .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private var resultSection: some View {
        Section("The result") {
            caretFitRow

            LabeledContent {
                HStack(spacing: 8) {
                    if settings.autoPasteEnabled, permissions.accessibility != .granted {
                        Button("Allow…") {
                            autoPaster.requestTrust()
                            onPermissionAction()
                        }
                    }
                    Toggle("Paste into the active app", isOn: autoPasteBinding)
                        .labelsHidden()
                }
            } label: {
                Text("Paste into the active app")
                if settings.autoPasteEnabled, permissions.accessibility != .granted {
                    Text("Needs Accessibility. Until it's allowed, results are only copied.")
                        .foregroundStyle(.orange)
                } else {
                    Text("The result is also copied")
                }
            }

            pasteOption(
                "Type it as it arrives",
                detail: "For providers that stream. Others paste when done.",
                isOn: $settings.streamingDeliveryEnabled
            )
            pasteOption(
                "Add a space after a word",
                detail: "Only when the cursor follows a word. The space isn't copied.",
                isOn: $settings.smartSpacingEnabled
            )
            pasteOption(
                "Stay in the original editor",
                detail: "If you switch apps before the result arrives, it's only copied",
                isOn: $settings.pinDeliveryTarget
            )
        }
    }

    /// Applies to what's copied as well as what's pasted, so it doesn't depend on paste.
    @ViewBuilder
    private var caretFitRow: some View {
        let isAvailable = CaretFitRow.isAvailable(permissions.accessibility)
        LabeledContent {
            Toggle(CaretFitRow.title, isOn: caretFitBinding(isAvailable: isAvailable))
                .labelsHidden()
                .accessibilityHint(isAvailable ? "" : CaretFitRow.accessibilityCue)
        } label: {
            Text(CaretFitRow.title)
            Text(CaretFitRow.detail)
        }
        .disabled(isAvailable == false)
        .help(isAvailable ? "" : CaretFitRow.accessibilityCue)

        if isAvailable == false {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(CaretFitRow.accessibilityCue)
                Spacer()
                Button("Open Privacy") {
                    navigation.selectedTab = .privacy
                }
            }
            .font(.callout)
        }
    }

    /// Off while Accessibility is missing, without writing to the stored preference.
    private func caretFitBinding(isAvailable: Bool) -> Binding<Bool> {
        Binding {
            isAvailable && settings.matchesSentenceAtCaret
        } set: { isOn in
            settings.matchesSentenceAtCaret = isOn
        }
    }

    private func pasteOption(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        LabeledContent {
            Toggle(title, isOn: isOn)
                .labelsHidden()
        } label: {
            Text(title)
            Text(detail)
        }
        .padding(.leading, 20)
        .disabled(settings.autoPasteEnabled == false)
    }

    private var soundSection: some View {
        Section {
            LabeledContent("When a result is ready") {
                HStack(spacing: 8) {
                    Picker("When a result is ready", selection: soundBinding) {
                        Text("No sound")
                            .tag(SuccessSound?.none)
                        Divider()
                        ForEach(SuccessSound.allCases) { sound in
                            Text(sound.displayName)
                                .tag(SuccessSound?.some(sound))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()

                    Button {
                        settings.successSound.play()
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(settings.playSounds == false)
                    .help("Play sound")
                    .accessibilityLabel("Play sound")
                }
            }
        } header: {
            Text("Sound")
        } footer: {
            Text("Errors show a notification when macOS allows Syrup to send them.")
                .font(.caption)
        }
    }

    private var soundBinding: Binding<SuccessSound?> {
        Binding {
            settings.playSounds ? settings.successSound : nil
        } set: { sound in
            settings.playSounds = sound != nil
            if let sound {
                settings.successSound = sound
                sound.play()
            }
        }
    }

    private var autoPasteBinding: Binding<Bool> {
        Binding {
            settings.autoPasteEnabled
        } set: { isEnabled in
            settings.autoPasteEnabled = isEnabled
            if isEnabled, autoPaster.isTrusted == false {
                autoPaster.requestTrust()
                onPermissionAction()
            }
        }
    }
}

/// "Match the sentence at the cursor" reads the text around the cursor with Accessibility.
enum CaretFitRow {
    static let title = "Match the sentence at the cursor"
    static let detail = "Starts lowercase mid-sentence and drops the final period before more text, in what Syrup copies and pastes."
    static let accessibilityCue = "Needs Accessibility to read the text around the cursor."

    static func isAvailable(_ accessibility: PermissionStatusModel.Status) -> Bool {
        accessibility == .granted
    }
}
