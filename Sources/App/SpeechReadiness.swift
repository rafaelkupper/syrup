import Foundation

/// Keeps speech recognition ready for the workflows a person can start, and picks each run's model.
/// Ready means the dictation locale's assets and any downloadable model, for the active workflow and
/// every voice workflow bound to a shortcut or an app route. A run whose model is not ready uses
/// Apple's, and the first such run in a launch says so.
@MainActor
final class SpeechReadiness {
    private let settings: AppSettings
    private let assetManager: TranscriberAssetManager
    private let models: [SpeechEngine: InstalledSpeechModel]
    /// The locales last handed to the asset manager for bound workflows; an unchanged set is not prepared again.
    private var preparedLocaleIDs: Set<String> = []
    private var didShowFallbackNotice = false

    init(settings: AppSettings, assetManager: TranscriberAssetManager, models: [SpeechEngine: InstalledSpeechModel]) {
        self.settings = settings
        self.assetManager = assetManager
        self.models = models
    }

    /// At launch: replaces an active locale this Mac cannot transcribe, then prepares every bound workflow.
    func refreshDictationLocales() async {
        await settings.refreshActiveDictationLocale { [assetManager] localeID in
            await assetManager.refreshSupportedLocales(selecting: localeID)
        }
        assetManager.prepareSelectedLocale(settings.activeWorkflow.dictationLocaleID)
        prepareBoundWorkflows()
    }

    /// Loads the downloadable models and prepares the locales of the workflows a shortcut or app
    /// route can start, and of the active workflow.
    func prepareBoundWorkflows() {
        let bound = settings.workflowList.workflows
            .filter { (HotkeyController.hasShortcut(forWorkflow: $0.id) || settings.workflowList.appRouting.values.contains($0.id)) && $0.input == .voice }
            + [settings.activeWorkflow]
        for engine in Set(bound.filter { $0.input == .voice }.map(\.speechEngine)) {
            models[engine]?.models.loadIfDownloaded()
        }
        let required = Set(bound.map {
            TranscriberAssetManager.bcp47Identifier(for: Locale(identifier: $0.dictationLocaleID))
        })
        guard required != preparedLocaleIDs else { return }
        preparedLocaleIDs = required
        assetManager.prepareLocales(Array(required))
    }

    /// The run's model, or nil and a notice when the model is not ready, in which case it starts loading.
    func modelSelection(for configuration: RunConfiguration) -> (transcriber: (any Transcriber)?, fallbackNotice: String?) {
        guard let installed = models[configuration.speechEngine] else { return (nil, nil) }
        guard let notice = installed.models.state.fallbackNotice(modelName: configuration.speechEngine.displayName) else {
            return (installed.transcriber, nil)
        }
        installed.models.loadIfDownloaded()
        return (nil, notice)
    }

    /// The fallback notice to show for a finished transcription, only the first time in a launch.
    func fallbackNoticeToShow(_ notice: String?) -> String? {
        guard let notice, didShowFallbackNotice == false else { return nil }
        didShowFallbackNotice = true
        return notice
    }
}
