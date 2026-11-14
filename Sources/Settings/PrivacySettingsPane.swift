import AppKit
import AVFoundation
import SwiftUI
import UserNotifications

struct PrivacySettingsPane: View {
    @Bindable var settings: AppSettings
    @Bindable var history: HistoryStore
    let usageStats: UsageStatsStore
    let permissions: PermissionStatusModel
    let autoPaster: any AutoPasting
    let onPermissionAction: () -> Void
    /// Reads the saved key, to name the endpoint runs actually use.
    let keychainStore: KeychainStore
    /// Folders the retired glossary learning left that the launch cleanup could not delete.
    @State private var retiredLearningLeftovers: [URL] = []
    @State private var retiredLearningDeletionFailed = false
    /// The endpoint a run would use, resolved like a run resolves it. In a Debug build with no saved
    /// key, a complete development environment overrides the saved endpoint.
    @State private var resolvedEndpointHost: String?

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
        .task {
            retiredLearningLeftovers = await RetiredGlossaryLearning.leftoversAfterLaunchCleanup()
        }
        .task(id: settings.baseURL + "\n" + settings.modelName) {
            resolvedEndpointHost = try? await OpenAICompatibleSettingsConfigurationResolver.configuration(
                baseURLString: settings.baseURL, modelName: settings.modelName, keychainStore: keychainStore
            ).baseURL.host()
        }
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
        HomeStatus.destination(
            provider: settings.translationProvider, baseURL: settings.baseURL, resolvedHost: resolvedEndpointHost
        )
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
                Text(settings.persistHistory ? "Results from now on are stored on this Mac" : "Off: the last \(HistoryStore.defaultCapacity) results stay in memory until Syrup quits. Turning it on keeps only later results.")
            }
            if let message = history.persistenceError {
                HStack(spacing: 8) {
                    Text(message)
                        .foregroundStyle(.red)
                    if history.leftoverFileRemains {
                        Button("Try Again") {
                            Task { await history.deleteLeftoverFileIfPersistenceIsOff() }
                        }
                    }
                }
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
                            Task { await usageStats.deleteAll() }
                        }
                    }
                    Toggle("Keep usage stats", isOn: $settings.keepsUsageStats)
                        .labelsHidden()
                }
            } label: {
                Text("Keep usage stats")
                Text("Counts and app names for Home, never your words")
            }
            if let message = usageStats.deletionError {
                Text(message)
                    .foregroundStyle(.red)
            }

            if retiredLearningLeftovers.isEmpty == false {
                retiredLearningRow
            }
        }
    }

    /// Recordings and the comparison model from the removed glossary learning, still on disk because
    /// the launch cleanup could not delete them.
    @ViewBuilder
    private var retiredLearningRow: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(retiredLearningLeftovers)
                }
                Button("Delete Now", role: .destructive) {
                    Task {
                        let remaining = await Task.detached(priority: .userInitiated) {
                            RetiredGlossaryLearning.removeLeftovers()
                        }.value
                        retiredLearningDeletionFailed = remaining.isEmpty == false
                        retiredLearningLeftovers = remaining
                    }
                }
            }
        } label: {
            Text("Files from glossary learning")
            Text(RetiredGlossaryLearning.leftoverDescription(for: retiredLearningLeftovers))
        }
        if retiredLearningDeletionFailed {
            Text("Couldn't delete these files. You can delete them in Finder.")
                .foregroundStyle(.red)
        }
    }

    private var persistHistoryBinding: Binding<Bool> {
        Binding {
            settings.persistHistory
        } set: { isEnabled in
            Task { await settings.privacyOptIns.setPersistHistory(isEnabled) }
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
