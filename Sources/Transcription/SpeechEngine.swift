import Foundation

enum SpeechEngine: String, CaseIterable, Identifiable, Sendable, Codable {
    case apple
    case parakeetUltra = "parakeet_ultra"
    case parakeetRedux = "parakeet_redux"
    case nemotronStreaming = "nemotron_streaming_3_5"
    case parakeetUnifiedEN = "parakeet_unified_en"
    case canaryFlash = "canary_180m_flash"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apple:
            "Apple"
        case .parakeetUltra:
            "Parakeet Ultra"
        case .parakeetRedux:
            "Parakeet Redux"
        case .nemotronStreaming:
            "Nemotron Streaming 3.5"
        case .parakeetUnifiedEN:
            "Parakeet Unified EN 0.6B"
        case .canaryFlash:
            "Canary 180M Flash"
        }
    }

    var tradeoff: String {
        switch self {
        case .apple:
            "Built into macOS. No download."
        case .parakeetUltra:
            "Runs on this Mac. The fewest errors on real Portuguese recordings of any model here. Apple shows the live preview."
        case .parakeetRedux:
            "Runs on this Mac. A third of Ultra's download, with a few more errors and a slower finish. Its first load after download takes several minutes. Apple shows the live preview."
        case .nemotronStreaming:
            "Runs on this Mac and shows its own words as you speak, in 28 languages."
        case .parakeetUnifiedEN:
            "Runs on this Mac and shows its own words as you speak. English only."
        case .canaryFlash:
            "Runs on this Mac. Small and quick, in English, German, Spanish, and French. Apple shows the live preview."
        }
    }

    /// One line for the model list.
    var tagline: String {
        switch self {
        case .apple:
            "Built into macOS, no download"
        case .parakeetUltra:
            "Most accurate final text in 25 European languages"
        case .parakeetRedux:
            "Smallest download, 25 European languages"
        case .nemotronStreaming:
            "Live multilingual transcription across 28 languages"
        case .parakeetUnifiedEN:
            "Fast, accurate live English transcription"
        case .canaryFlash:
            "Tiny and instant, in four languages"
        }
    }

    /// Streaming engines supply their own live text. Apple then runs only as the fallback.
    var isStreaming: Bool {
        switch self {
        case .apple, .parakeetUltra, .parakeetRedux, .canaryFlash:
            false
        case .nemotronStreaming, .parakeetUnifiedEN:
            true
        }
    }

    /// Where the model sits under the shared speech model folder. Nil means nothing to download.
    var modelFolder: String? {
        switch self {
        case .apple:
            nil
        case .parakeetUltra:
            "parakeet-ultra"
        case .parakeetRedux:
            "parakeet-redux"
        case .nemotronStreaming:
            "nemotron-multilingual"
        case .parakeetUnifiedEN:
            "parakeet-unified-en-0.6b"
        case .canaryFlash:
            "canary-180m-flash-coreml"
        }
    }

    var downloadSize: String? {
        switch self {
        case .apple:
            nil
        case .parakeetUltra:
            "632 MB"
        case .parakeetRedux:
            "220 MB"
        case .nemotronStreaming:
            "640 MB"
        case .parakeetUnifiedEN:
            "595 MB"
        case .canaryFlash:
            "256 MB"
        }
    }

    var languageSummary: String {
        switch self {
        case .apple:
            "Installed languages"
        case .parakeetUltra, .parakeetRedux:
            "\(Self.parakeetLanguageCodes.count) languages"
        case .nemotronStreaming:
            "\(Self.nemotronLanguageCodes.count) languages"
        case .parakeetUnifiedEN:
            "English"
        case .canaryFlash:
            "4 languages"
        }
    }

    /// Five-step bars from real recordings. See docs/verification/2026-11-04-parakeet-ultra-redux.md.
    var measuredScores: (accuracy: Int, speed: Int) {
        switch self {
        case .apple:
            (accuracy: 3, speed: 3)
        case .parakeetUltra:
            (accuracy: 5, speed: 2)
        case .parakeetRedux:
            (accuracy: 4, speed: 1)
        case .nemotronStreaming:
            (accuracy: 2, speed: 5)
        case .parakeetUnifiedEN:
            (accuracy: 4, speed: 5)
        case .canaryFlash:
            (accuracy: 3, speed: 4)
        }
    }

    /// Parakeet v3's model card languages, which Ultra and Redux keep.
    private static let parakeetLanguageCodes: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
        "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    /// The 28 languages of the 32 locales NVIDIA lists as transcription-ready or broad-coverage.
    /// The 8 adaptation-ready ones need fine-tuning, so they are left out.
    private static let nemotronLanguageCodes: Set<String> = [
        "ar", "bg", "cs", "da", "de", "en", "es", "et", "fi", "fr", "hi", "hr", "hu", "it",
        "ja", "ko", "nb", "nl", "pl", "pt", "ro", "ru", "sk", "sv", "tr", "uk", "vi", "zh",
    ]

    /// Workflows saved by 0.9 or earlier may have chosen Parakeet v3, which Ultra replaced.
    init(from decoder: any Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = rawValue == Self.retiredParakeetV3 ? .parakeetUltra : SpeechEngine(rawValue: rawValue) ?? .apple
    }

    static let retiredParakeetV3 = "parakeet_v3"
    /// Where 0.9 kept the v3 download, under the shared speech model folder.
    static let retiredParakeetV3Folder = "parakeet-tdt-0.6b-v3"

    static func languageCode(for localeID: String) -> String? {
        Locale(identifier: localeID).language.languageCode?.identifier
    }

    func supports(localeID: String) -> Bool {
        let code = Self.languageCode(for: localeID)
        switch self {
        case .apple:
            return true
        case .parakeetUltra, .parakeetRedux:
            return code.map(Self.parakeetLanguageCodes.contains) ?? false
        case .nemotronStreaming:
            return code.map(Self.nemotronLanguageCodes.contains) ?? false
        case .parakeetUnifiedEN:
            return code == "en"
        case .canaryFlash:
            return code.map(CanaryModel.languages.contains) ?? false
        }
    }
}
