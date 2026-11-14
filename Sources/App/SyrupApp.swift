import AppKit
import SwiftUI

/// Chooses the app before any production service starts. A unit-test host gets an inert app,
/// so `xcodebuild test` never registers hotkeys, starts downloads, or runs retention cleanup.
@main
enum SyrupMain {
    @MainActor static func main() {
        if TestHost.isActive {
            TestHostApp.main()
        } else {
            SyrupApp.main()
        }
    }
}

enum TestHost {
    static var isActive: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }
}

private struct TestHostApp: App {
    var body: some Scene { Settings { EmptyView() } }
}

final class SyrupAppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?
    var prepareForTermination: (@MainActor () async -> Void)?

    /// Opening Syrup while it is already running shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow?()
        return true
    }

    /// Every quit path (menu, Command-Q, logout, an update relaunch) ends the run, restores the
    /// output volume, and writes pending history before the process exits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let prepareForTermination else { return .terminateNow }
        self.prepareForTermination = nil
        Task { @MainActor in
            await prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
                delegate.prepareForTermination = { [state] in
                    await state.prepareForTermination()
                }
            }
    }
}

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
        let appState = AppState.production(
            settings: AppSettings(defaultMicrophoneIDProvider: AudioInputDevice.defaultSelectionID),
            speechModels: speechModels.installed,
            recordingArchive: recordingArchive
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
            await deleteLeftoverRecordingsIfLearningIsOff(settings: appState.settings, recordingArchive: recordingArchive)
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

extension AppState {
    /// The production services. Only the app entry point builds them; tests inject their own.
    static func production(
        settings: AppSettings,
        speechModels: [SpeechEngine: InstalledSpeechModel],
        recordingArchive: any RecordingArchiving
    ) -> AppState {
        let transcriberAssetManager = TranscriberAssetManager()
        let keychainStore = KeychainStore()
        return AppState(
            settings: settings,
            transcriberAssetManager: transcriberAssetManager,
            history: HistoryStore(persistenceEnabled: settings.persistHistory),
            keychainStore: keychainStore,
            audioRecorder: AudioRecorder(settings: settings),
            transcriber: AppleTranscriber(assetManager: transcriberAssetManager),
            speechModels: speechModels,
            usageStats: UsageStatsStore(fileURL: UsageStatsStore.defaultFileURL()),
            transformerProvider: AppSettingsTransformerProvider(settings: settings, keychainStore: keychainStore),
            pasteboard: ClipboardWriter(),
            feedback: AppFeedback(),
            metrics: PipelineMetricsRecorder(),
            autoPaster: AutoPaster(),
            streamingTypistFactory: { StreamingTypist() },
            selectionReader: SelectionReader(),
            processActivity: ProcessInfo.processInfo,
            recordingCue: RecordingCueController(),
            recordingArchive: recordingArchive,
            outputDucker: OutputDucker(),
            frontmostApplication: { includeBundleID in
                let app = NSWorkspace.shared.frontmostApplication
                return (includeBundleID ? app?.bundleIdentifier : nil, app?.processIdentifier)
            },
            captureDeliveryTarget: { await DeliveryTarget.capture(processID: $0) },
            installHotkeys: true
        )
    }
}
