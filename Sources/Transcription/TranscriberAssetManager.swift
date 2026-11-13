import Foundation
import Observation
import Speech

struct DictationLocaleOption: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let displayName: String
}

enum TranscriptionError: Error, Equatable {
    case speechRecognitionAccessDenied
    case speechRecognitionRestricted
    case speechTranscriberUnavailable
    case localeNotSupported(String)
    case languageModelInstalling(String)
    case languageModelUnavailable(String)
    case noCompatibleAudioFormat
    case audioConversionFailed
    case finalizationTimedOut
}

@MainActor
@Observable
final class TranscriberAssetManager: @unchecked Sendable {
    enum AssetState: Equatable, Sendable {
        case unknown
        case checking
        case installed(String)
        case downloading(String, Double?)
        case unsupported(String)
        case failed(String)
    }

    var supportedLocales: [DictationLocaleOption] = []
    var selectedLocaleAssetState: AssetState = .unknown

    @ObservationIgnored private var preparationTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var progressTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var localeStates: [String: AssetState] = [:]
    @ObservationIgnored private var selectedLocaleID: String?
    @ObservationIgnored private var installedLocaleCache = TranscriberInstalledLocaleCache()

    @ObservationIgnored private let prepareOverride: (@Sendable (String) async -> AssetState)?

    init(prepare: (@Sendable (String) async -> AssetState)? = nil) {
        prepareOverride = prepare
    }

    var selectedLocaleAssetMessage: String {
        switch selectedLocaleAssetState {
        case .unknown:
            "Language model status unknown"
        case .checking:
            "Checking language model..."
        case .installed(let languageName):
            "\(languageName) language model ready"
        case .downloading(let languageName, _):
            "Downloading \(languageName) language model..."
        case .unsupported(let languageName):
            "\(languageName) is not supported for on-device transcription"
        case .failed(let languageName):
            "\(languageName) language model could not be installed"
        }
    }

    var selectedLocaleProgress: Double? {
        guard case .downloading(_, let progress) = selectedLocaleAssetState else {
            return nil
        }
        return progress
    }

    func refreshSupportedLocales(selecting selectedLocaleID: String) async -> String? {
        guard SpeechTranscriber.isAvailable else {
            supportedLocales = []
            selectedLocaleAssetState = .failed("On-device transcription")
            return nil
        }

        let locales = await SpeechTranscriber.supportedLocales
        supportedLocales = Self.localeOptions(from: locales)

        guard supportedLocales.isEmpty == false else {
            selectedLocaleAssetState = .failed("On-device transcription")
            return nil
        }

        if supportedLocales.contains(where: { $0.id == selectedLocaleID }) {
            return nil
        }

        let selectedLocale = Locale(identifier: selectedLocaleID)
        if let equivalentLocale = await SpeechTranscriber.supportedLocale(equivalentTo: selectedLocale) {
            return Self.bcp47Identifier(for: equivalentLocale)
        }

        if let englishLocale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) {
            return Self.bcp47Identifier(for: englishLocale)
        }

        return supportedLocales.first?.id
    }

    func prepareSelectedLocale(_ localeID: String) {
        let key = Self.bcp47Identifier(for: Locale(identifier: localeID))
        selectedLocaleID = key
        selectedLocaleAssetState = localeStates[key] ?? .unknown
        prepareLocale(key)
    }

    func prepareLocales(_ localeIDs: [String]) {
        for localeID in Set(localeIDs) {
            prepareLocale(Self.bcp47Identifier(for: Locale(identifier: localeID)))
        }
    }

    private func prepareLocale(_ key: String) {
        guard preparationTasks[key] == nil else { return }
        if case .installed = localeStates[key] { return }
        setState(.checking, for: key)
        preparationTasks[key] = Task { [weak self] in
            if let prepare = self?.prepareOverride {
                let state = await prepare(key)
                self?.setState(state, for: key)
            } else {
                await self?.prepare(localeID: key)
            }
            self?.preparationTasks[key] = nil
        }
    }

    private func setState(_ state: AssetState, for localeID: String) {
        localeStates[localeID] = state
        if selectedLocaleID == localeID { selectedLocaleAssetState = state }
    }

    func invalidateInstalledLocale(_ locale: Locale) {
        installedLocaleCache.remove(locale)
        localeStates[Self.bcp47Identifier(for: locale)] = nil
    }

    func requireInstalled(locale requestedLocale: Locale, allowPreparation: Bool = true) async throws -> Locale {
        let localeID = Self.bcp47Identifier(for: requestedLocale)
        if allowPreparation {
            try await requestSpeechAuthorization()
        } else {
            guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
                throw TranscriptionError.speechRecognitionAccessDenied
            }
        }

        if allowPreparation, let cachedLocale = installedLocaleCache.installedLocale(equivalentTo: requestedLocale) {
            setState(.installed(Self.displayName(for: cachedLocale)), for: localeID)
            return cachedLocale
        }

        guard SpeechTranscriber.isAvailable else {
            setState(.failed("On-device transcription"), for: localeID)
            throw TranscriptionError.speechTranscriberUnavailable
        }

        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            let languageName = Self.displayName(for: requestedLocale)
            setState(.unsupported(languageName), for: localeID)
            throw TranscriptionError.localeNotSupported(languageName)
        }

        let languageName = Self.displayName(for: supportedLocale)
        let installedLocales = await SpeechTranscriber.installedLocales
        guard Self.locales(installedLocales, contain: supportedLocale) else {
            installedLocaleCache.remove(supportedLocale)
            if allowPreparation {
                prepareLocale(Self.bcp47Identifier(for: supportedLocale))
                throw TranscriptionError.languageModelInstalling(languageName)
            }
            throw TranscriptionError.languageModelUnavailable(languageName)
        }

        installedLocaleCache.storeInstalled(supportedLocale)
        setState(.installed(languageName), for: localeID)
        return supportedLocale
    }

    private func prepare(localeID: String) async {
        guard SpeechTranscriber.isAvailable else {
            setState(.failed("On-device transcription"), for: localeID)
            return
        }

        let requestedLocale = Locale(identifier: localeID)
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            setState(.unsupported(Self.displayName(for: requestedLocale)), for: localeID)
            return
        }

        let languageName = Self.displayName(for: supportedLocale)
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        let installedLocales = await SpeechTranscriber.installedLocales
        if Self.locales(installedLocales, contain: supportedLocale) {
            installedLocaleCache.storeInstalled(supportedLocale)
            setState(.installed(languageName), for: localeID)
            return
        }

        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                setState(.installed(languageName), for: localeID)
                return
            }

            observeProgress(request.progress, languageName: languageName, localeID: localeID)
            try await request.downloadAndInstall()
            progressTasks[localeID]?.cancel()
            installedLocaleCache.storeInstalled(supportedLocale)
            setState(.installed(languageName), for: localeID)
        } catch is CancellationError {
            progressTasks[localeID]?.cancel()
        } catch {
            progressTasks[localeID]?.cancel()
            installedLocaleCache.remove(supportedLocale)
            setState(.failed(languageName), for: localeID)
        }
    }

    private func observeProgress(_ progress: Progress, languageName: String, localeID: String) {
        setState(.downloading(languageName, normalizedProgress(progress.fractionCompleted)), for: localeID)
        progressTasks[localeID]?.cancel()
        progressTasks[localeID] = Task { [weak self] in
            while Task.isCancelled == false, progress.isFinished == false {
                self?.setState(.downloading(languageName, self?.normalizedProgress(progress.fractionCompleted)), for: localeID)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func requestSpeechAuthorization() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .denied:
            throw TranscriptionError.speechRecognitionAccessDenied
        case .restricted:
            throw TranscriptionError.speechRecognitionRestricted
        case .notDetermined:
            let status = await SpeechPermissionRequester.requestAuthorization()

            switch status {
            case .authorized:
                return
            case .denied, .notDetermined:
                throw TranscriptionError.speechRecognitionAccessDenied
            case .restricted:
                throw TranscriptionError.speechRecognitionRestricted
            @unknown default:
                throw TranscriptionError.speechRecognitionAccessDenied
            }
        @unknown default:
            throw TranscriptionError.speechRecognitionAccessDenied
        }
    }

    private func normalizedProgress(_ fractionCompleted: Double) -> Double? {
        guard fractionCompleted.isFinite else {
            return nil
        }
        return min(max(fractionCompleted, 0), 1)
    }

    static func locales(_ locales: [Locale], contain locale: Locale) -> Bool {
        let identifier = bcp47Identifier(for: locale)
        return locales.contains { bcp47Identifier(for: $0) == identifier }
    }

    static func bcp47Identifier(for locale: Locale) -> String {
        locale.identifier(.bcp47)
    }

    static func displayName(for locale: Locale) -> String {
        let identifier = bcp47Identifier(for: locale)
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    private static func localeOptions(from locales: [Locale]) -> [DictationLocaleOption] {
        locales
            .map { locale in
                let identifier = bcp47Identifier(for: locale)
                return DictationLocaleOption(
                    id: identifier,
                    displayName: Locale.current.localizedString(forIdentifier: identifier) ?? identifier
                )
            }
            .sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
    }
}

@MainActor
struct TranscriberInstalledLocaleCache {
    private var localesByIdentifier: [String: Locale] = [:]

    mutating func storeInstalled(_ locale: Locale) {
        localesByIdentifier[TranscriberAssetManager.bcp47Identifier(for: locale)] = locale
    }

    mutating func remove(_ locale: Locale) {
        localesByIdentifier.removeValue(forKey: TranscriberAssetManager.bcp47Identifier(for: locale))
    }

    func installedLocale(equivalentTo requestedLocale: Locale) -> Locale? {
        let requestedIdentifier = TranscriberAssetManager.bcp47Identifier(for: requestedLocale)
        return localesByIdentifier[requestedIdentifier]
    }
}
