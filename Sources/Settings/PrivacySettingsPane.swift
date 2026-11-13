import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

struct PrivacySettingsPane: View {
    @Bindable var settings: AppSettings
    @Bindable var history: HistoryStore
    let usageStats: UsageStatsStore
    @Bindable var navigation: SettingsNavigation
    let permissions: PermissionStatusModel
    let autoPaster: any AutoPasting
    let onPermissionAction: () -> Void

    var body: some View {
        Form {
            Section {
                microphoneRow
                speechRow
                notificationsRow
                accessibilityRow
            } header: {
                Text("Permissions")
            } footer: {
                Text("Syrup asks only when you first use a feature. This page updates when you come back from System Settings.")
                    .font(.caption)
            }

            leavingSection
            keptSection
        }
        .formStyle(.grouped)
    }

    private var leavingSection: some View {
        Section {
            LabeledContent {
                destinationLabel(nil)
            } label: {
                Text("Audio")
                Text("Never sent anywhere")
            }

            LabeledContent {
                destinationLabel(defaultDestination)
            } label: {
                Text("What you said, and your glossary")
                Text("Sent with each run. Transcribe workflows send nothing.")
            }

            LabeledContent {
                destinationLabel(defaultDestination)
            } label: {
                Text("Selected text")
                Text("Only for workflows that include it. Never saved.")
            }
        } header: {
            Text("What leaves this Mac")
        } footer: {
            Text(destinationFootnote)
                .font(.caption)
        }
    }

    private var defaultDestination: String? {
        HomeStatus.destination(provider: settings.translationProvider, baseURL: settings.baseURL)
    }

    private func destinationLabel(_ destination: String?) -> some View {
        Label(destination ?? "This Mac", systemImage: destination == nil ? "laptopcomputer" : "cloud")
            .font(.callout)
            .foregroundStyle(destination == nil ? .green : .orange)
    }

    /// Names workflows whose provider differs from the default, because their text goes elsewhere.
    private var destinationFootnote: String {
        let overrides = settings.workflowList.workflows.filter { workflow in
            workflow.kind.isTranscribeOnly == false
                && workflow.translationProvider != nil
                && workflow.translationProvider != settings.translationProvider
        }
        guard overrides.isEmpty == false else {
            return "Shows your default provider, which every workflow uses."
        }
        let names = overrides.map { "\($0.name) uses \($0.translationProvider?.displayName ?? "")" }
        return "Shows your default provider. " + names.formatted(.list(type: .and)) + "."
    }

    private var keptSection: some View {
        Section("What’s kept") {
            LabeledContent {
                Toggle("Keep history across restarts", isOn: persistHistoryBinding)
                    .disabled(history.isChangingPersistence)
                    .labelsHidden()
            } label: {
                Text("Keep history across restarts")
                Text(settings.persistHistory ? "Stored on this Mac" : "Off: the last \(HistoryStore.defaultCapacity) results stay in memory until Syrup quits")
            }
            if let message = history.persistenceError {
                Text(message)
                    .foregroundStyle(.red)
            }

            LabeledContent {
                HStack(spacing: 8) {
                    if usageStats.stats.isEmpty == false {
                        Button("Delete Stats…", role: .destructive) {
                            guard confirmDestructiveAction(
                                message: "Delete your usage stats?",
                                detail: "Word counts, speed, streaks, and top apps are deleted from this Mac. This can't be undone.",
                                confirmTitle: "Delete Stats"
                            ) else { return }
                            usageStats.deleteAll()
                        }
                    }
                    Toggle("Keep usage stats", isOn: $settings.keepsUsageStats)
                        .labelsHidden()
                }
            } label: {
                Text("Keep usage stats")
                Text("Counts and app names for Home, never your words")
            }

            LabeledContent {
                Button("Show in Glossary") {
                    navigation.selectedTab = .glossary
                }
            } label: {
                Text("Recordings for glossary learning")
                Text(settings.glossaryLearningEnabled ? "On. Kept on this Mac until compared, at most 50 for 7 days." : "Off. Nothing is kept.")
            }
        }
    }

    private var persistHistoryBinding: Binding<Bool> {
        Binding {
            settings.persistHistory
        } set: { isEnabled in
            Task {
                if await history.setPersistenceEnabled(isEnabled) { settings.persistHistory = isEnabled }
            }
        }
    }

    private var microphoneRow: some View {
        permissionRow(
            title: "Microphone",
            description: "Records your voice for dictation",
            status: permissions.microphone
        ) {
            switch permissions.microphone {
            case .notRequested:
                Button("Allow…") {
                    Task { @MainActor in
                        await PermissionActions.requestMicrophone()
                        onPermissionAction()
                    }
                }
            case .denied, .restricted:
                Button("Open System Settings…") {
                    PermissionActions.open(.microphone)
                }
            case .granted, .unknown:
                EmptyView()
            }
        }
    }

    private var speechRow: some View {
        permissionRow(
            title: "Speech Recognition",
            description: "Turns your voice into text on this Mac",
            status: permissions.speech
        ) {
            switch permissions.speech {
            case .notRequested:
                Button("Allow…") {
                    Task { @MainActor in
                        await PermissionActions.requestSpeechRecognition()
                        onPermissionAction()
                    }
                }
            case .denied, .restricted:
                Button("Open System Settings…") {
                    PermissionActions.open(.speechRecognition)
                }
            case .granted, .unknown:
                EmptyView()
            }
        }
    }

    private var notificationsRow: some View {
        permissionRow(
            title: "Notifications",
            description: "Tells you when a dictation fails",
            status: permissions.notifications
        ) {
            switch permissions.notifications {
            case .notRequested:
                Button("Allow…") {
                    Task { @MainActor in
                        _ = try? await UNUserNotificationCenter.current()
                            .requestAuthorization(options: [.alert, .sound])
                        onPermissionAction()
                    }
                }
            case .denied, .restricted:
                Button("Open System Settings…") {
                    PermissionActions.open(.notifications)
                }
            case .granted, .unknown:
                EmptyView()
            }
        }
    }

    private var accessibilityRow: some View {
        permissionRow(
            title: "Accessibility",
            description: "Pastes results and reads selected text. Dictation works without it.",
            status: permissions.accessibility
        ) {
            if permissions.accessibility == .granted {
                Button("Open System Settings…") {
                    PermissionActions.open(.accessibility)
                }
            } else {
                Button("Allow…") {
                    autoPaster.requestTrust()
                    onPermissionAction()
                }
            }
        }
    }

    private func permissionRow(
        title: String,
        description: String,
        status: PermissionStatusModel.Status,
        @ViewBuilder action: () -> some View
    ) -> some View {
        LabeledContent {
            HStack(spacing: 10) {
                StatusPill(status)
                action()
            }
        } label: {
            Text(title)
            Text(description)
        }
    }
}

/// Permission requests shared by Privacy and onboarding.
@MainActor
enum PermissionActions {
    enum SettingsPane: String {
        case microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case speechRecognition = "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case notifications = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    }

    static func requestMicrophone() async {
        _ = await AVAudioApplication.requestRecordPermission()
    }

    static func requestSpeechRecognition() async {
        _ = await SpeechPermissionRequester.requestAuthorization()
    }

    static func open(_ pane: SettingsPane) {
        guard let url = URL(string: pane.rawValue) else { return }
        NSWorkspace.shared.open(url)
    }
}
