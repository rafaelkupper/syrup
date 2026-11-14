import AppKit
import SwiftUI

/// The Syrup window: Home and settings as toolbar tabs.
struct SettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    let state: AppState
    @Bindable var settings: AppSettings
    let updates: UpdateController
    @Bindable var assetManager: TranscriberAssetManager
    let speechModels: SpeechModelCatalog
    @Bindable var history: HistoryStore
    @Bindable var navigation: SettingsNavigation
    let keychainStore: KeychainStore
    let autoPaster: any AutoPasting
    let recordingArchive: (any RecordingArchiving)?
    @Bindable var whisperModelManager: WhisperModelManager
    let learningCoordinator: GlossaryLearningCoordinator?
    let workflowChangeHandler: () -> Void
    let settingsWindowFocusController = SettingsWindowFocusController()
    @State private var permissions = PermissionStatusModel()

    static let standardSize = CGSize(width: 720, height: 640)
    static let workflowsSize = CGSize(width: 900, height: 660)

    var body: some View {
        TabView(selection: $navigation.selectedTab) {
            tab(.home) {
                HomeSettingsPane(
                    state: state,
                    speechModels: speechModels,
                    navigation: navigation,
                    permissions: permissions,
                    onPasteEnabled: requestPasteTrustIfNeeded
                )
            }
            tab(.workflows, size: Self.workflowsSize) {
                WorkflowsSettingsPane(
                    settings: settings,
                    assetManager: assetManager,
                    speechModels: speechModels,
                    navigation: navigation,
                    onPasteEnabled: requestPasteTrustIfNeeded,
                    shortcutChangeHandler: workflowChangeHandler
                )
            }
            tab(.dictation) {
                DictationSettingsPane(settings: settings, shortcutChangeHandler: workflowChangeHandler)
            }
            tab(.delivery) {
                DeliverySettingsPane(
                    settings: settings,
                    autoPaster: autoPaster,
                    permissions: permissions,
                    navigation: navigation,
                    onPermissionAction: completePermissionAction
                )
            }
            tab(.models) {
                ModelsSettingsPane(settings: settings, speechModels: speechModels, keychainStore: keychainStore)
            }
            tab(.glossary) {
                GlossarySettingsView(
                    settings: settings,
                    navigation: navigation,
                    recordingArchive: recordingArchive,
                    whisperModelManager: whisperModelManager,
                    learningCoordinator: learningCoordinator
                )
            }
            // Toolbar tabs don't draw badges, so the icon carries the warning.
            Tab(
                SettingsNavigation.Tab.privacy.title,
                systemImage: permissions.attentionCount > 0 ? "exclamationmark.shield" : SettingsNavigation.Tab.privacy.systemImage,
                value: .privacy
            ) {
                PrivacySettingsPane(
                    settings: settings,
                    history: history,
                    usageStats: state.usageStats,
                    recordingArchive: state.recordingArchive,
                    navigation: navigation,
                    permissions: permissions,
                    autoPaster: autoPaster,
                    onPermissionAction: completePermissionAction
                )
                .frame(width: Self.standardSize.width, height: Self.standardSize.height)
            }
            tab(.general) {
                GeneralSettingsPane(updates: updates)
            }
        }
        .toggleStyle(.switch)
        .onAppear {
            permissions.refresh(autoPaster: autoPaster)
            workflowChangeHandler()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                permissions.refresh(autoPaster: autoPaster)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh(autoPaster: autoPaster)
        }
        .task {
            await refreshDictationLocales()
        }
        .onChange(of: settings.workflowList) { _, _ in
            workflowChangeHandler()
        }
    }

    private func tab(
        _ value: SettingsNavigation.Tab,
        size: CGSize = SettingsView.standardSize,
        @ViewBuilder content: () -> some View
    ) -> some TabContent<SettingsNavigation.Tab> {
        Tab(value.title, systemImage: value.systemImage, value: value) {
            content()
                .frame(width: size.width, height: size.height)
        }
    }

    private func refreshDictationLocales() async {
        await settings.refreshActiveDictationLocale { [assetManager] localeID in
            await assetManager.refreshSupportedLocales(selecting: localeID)
        }
        assetManager.prepareSelectedLocale(settings.activeWorkflow.dictationLocaleID)
    }

    /// Pasting needs Accessibility. Ask when something turns it on and the app isn't trusted yet.
    private func requestPasteTrustIfNeeded() {
        guard autoPaster.isTrusted == false else { return }
        autoPaster.requestTrust()
        completePermissionAction()
    }

    private func completePermissionAction() {
        permissions.refresh(autoPaster: autoPaster)
        settingsWindowFocusController.refocusVisibleWindows()
        settingsWindowFocusController.refocusVisibleWindows(afterNanoseconds: 300_000_000)
        settingsWindowFocusController.refocusVisibleWindows(afterNanoseconds: 1_000_000_000)
    }
}
