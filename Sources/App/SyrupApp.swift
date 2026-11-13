import AppKit
import SwiftUI

final class SyrupAppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?

    /// Opening Syrup while it is already running shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow?()
        return true
    }
}

/// Always on screen, so it is where the app delegate gets a way to open the window.
private struct MenuBarLabel: View {
    @Environment(\.openSettings) private var openSettings
    let state: AppState
    let delegate: SyrupAppDelegate

    var body: some View {
        Image(systemName: state.menuBarSymbol)
            .symbolEffect(
                .variableColor.iterative.dimInactiveLayers,
                options: .repeat(.continuous),
                isActive: state.isMenuBarSymbolAnimated
            )
            .accessibilityLabel("Syrup")
            .onAppear {
                delegate.openMainWindow = {
                    NSApp.activate()
                    openSettings()
                }
            }
    }
}

@main
struct SyrupApp: App {
    @NSApplicationDelegateAdaptor(SyrupAppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @State private var settingsNavigation = SettingsNavigation()
    @State private var whisperModelManager: WhisperModelManager
    private let speechModels: SpeechModelCatalog
    private let updates: UpdateController
    private let learningCoordinator: GlossaryLearningCoordinator
    private let mishearingSuggestions: MishearingSuggestionModel
    private let showsOnboardingAtLaunch: Bool

    init() {
        showsOnboardingAtLaunch = OnboardingGate.resolve()
        let recordingArchive = RecordingArchive()
        let whisperModelManager = WhisperModelManager()
        let speechModels = SpeechModelCatalog.live()
        speechModels.replaceRetiredParakeetV3()
        let appState = AppState(
            speechModels: speechModels.installed,
            usageStats: UsageStatsStore(fileURL: UsageStatsStore.defaultFileURL()),
            installHotkeys: true,
            recordingCue: RecordingCueController(),
            recordingArchive: recordingArchive,
            outputDucker: OutputDucker()
        )
        appState.restoreOutputVolumeAfterCrash()
        _appState = State(initialValue: appState)
        _whisperModelManager = State(initialValue: whisperModelManager)
        self.speechModels = speechModels
        let judge = LLMMishearingJudge(
            transformerProvider: AppSettingsTransformerProvider(
                settings: appState.settings,
                keychainStore: appState.keychainStore
            ),
            providerReader: { appState.settings.translationProvider }
        )
        learningCoordinator = GlossaryLearningCoordinator(
            settings: appState.settings,
            archive: recordingArchive,
            modelManager: whisperModelManager,
            transcriber: WhisperKitBatchTranscriber(
                modelDirectory: whisperModelManager.modelDirectory
            ),
            sink: JudgingCrossCheckSink(settings: appState.settings, judge: judge)
        )
        mishearingSuggestions = MishearingSuggestionModel(
            settings: appState.settings,
            engine: MishearingProbeEngine(
                synthesizer: SystemMishearingSynthesizer(),
                recognizer: AppleMishearingRecognizer(assetManager: appState.transcriberAssetManager),
                wordChecker: SystemMishearingWordChecker()
            )
        )
        let updates = UpdateController(isRunActive: { appState.pipelineState.allowsCancelShortcut })
        self.updates = updates
        appState.foregroundActivityChanged = { [learningCoordinator, mishearingSuggestions, updates] active in
            if !active {
                Task { @MainActor in updates.resumeDeferredInstallation() }
            }
            learningCoordinator.setForegroundActive(active)
            mishearingSuggestions.setForegroundActive(active)
        }
        Task { @MainActor in
            let learningEnabled = appState.settings.glossaryLearningEnabled
            await applyGlossaryLearningRetentionChange(
                isEnabled: learningEnabled,
                settings: appState.settings,
                recordingArchive: recordingArchive,
                revertsSettingOnFailure: false
            )
            if learningEnabled {
                _ = await recordingArchive.pendingEntries()
            }
        }
        Task { @MainActor in
            await appState.refreshDictationLocales()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                updates: updates,
                state: appState,
                settingsNavigation: settingsNavigation
            )
        } label: {
            MenuBarLabel(state: appState, delegate: appDelegate)
        }

        Settings {
            SettingsView(
                state: appState,
                settings: appState.settings,
                updates: updates,
                assetManager: appState.transcriberAssetManager,
                speechModels: speechModels,
                history: appState.history,
                navigation: settingsNavigation,
                keychainStore: appState.keychainStore,
                autoPaster: appState.autoPaster,
                recordingArchive: appState.recordingArchive,
                whisperModelManager: whisperModelManager,
                learningCoordinator: learningCoordinator,
                workflowChangeHandler: {
                    appState.refreshWorkflowHotkeys()
                }
            )
            .environment(mishearingSuggestions)
        }

        Window("Welcome to Syrup", id: OnboardingWindow.id) {
            OnboardingView(
                state: appState,
                settings: appState.settings,
                assetManager: appState.transcriberAssetManager,
                autoPaster: appState.autoPaster,
                keychainStore: appState.keychainStore
            )
            .windowResizeBehavior(.disabled)
            .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(showsOnboardingAtLaunch ? .presented : .suppressed)
        .restorationBehavior(.disabled)
    }
}
