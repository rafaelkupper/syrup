import Foundation

enum OnboardingWindow {
    static let id = "onboarding"
}

/// Decides whether the welcome window opens by itself. Call `resolve` before `AppSettings` is created, because creating it writes defaults.
enum OnboardingGate {
    private static let stateKey = "onboardingState"
    private static let pending = "pending"
    private static let done = "done"
    private static let existingSettingsKeys = ["workflowListV3", "workflowListV1", "dictationLocaleID", "targetLanguage"]

    @discardableResult
    static func resolve(_ defaults: UserDefaults = .standard) -> Bool {
        switch defaults.string(forKey: stateKey) {
        case pending:
            return true
        case done:
            return false
        default:
            let isFresh = existingSettingsKeys.allSatisfy { defaults.object(forKey: $0) == nil }
            defaults.set(isFresh ? pending : done, forKey: stateKey)
            return isFresh
        }
    }

    static func isPending(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.string(forKey: stateKey) == pending
    }

    static func markDone(_ defaults: UserDefaults = .standard) {
        defaults.set(done, forKey: stateKey)
    }
}

enum OnboardingStep: Equatable {
    case welcome
    case permissions
    case recipe
    case flavor
    case taste

    /// Transcribe workflows use no AI provider, so they have nothing to choose in Flavor.
    static func steps(for kind: WorkflowKind) -> [OnboardingStep] {
        kind.isTranscribeOnly ? [.welcome, .permissions, .recipe, .taste] : [.welcome, .permissions, .recipe, .flavor, .taste]
    }
}

enum OnboardingTarget: Hashable {
    case sameLanguage
    case language(String)
}

enum OnboardingRecipe {
    private static let translateName = "Translate"
    private static let transcribeName = "Transcribe"

    /// The supported locale closest to this Mac's language. Nil keeps the current choice.
    static func preferredLocale(current: Locale, supported: [DictationLocaleOption]) -> String? {
        let exact = current.identifier.replacingOccurrences(of: "_", with: "-")
        if let match = supported.first(where: { $0.id == exact }) {
            return match.id
        }
        guard let language = current.language.languageCode?.identifier else { return nil }
        // A region with no match, like English in Brazil, uses the language's main region rather than the first in the list.
        if let region = Locale.Language(identifier: Locale.Language(identifier: language).maximalIdentifier).region?.identifier,
           let match = supported.first(where: { $0.id == "\(language)-\(region)" }) {
            return match.id
        }
        return supported.first { Locale(identifier: $0.id).language.languageCode?.identifier == language }?.id
    }

    /// Translating English into English is pointless, so an English speaker starts with Transcribe.
    static func defaultTarget(dictationLocaleID: String, fallback: String) -> OnboardingTarget {
        let language = Locale(identifier: dictationLocaleID).language.languageCode?.identifier
        return language == "en" && fallback.lowercased().hasPrefix("english") ? .sameLanguage : .language(fallback)
    }

    static func target(of kind: WorkflowKind) -> OnboardingTarget? {
        switch kind {
        case .translation(let targetLanguage, _, _):
            .language(targetLanguage)
        case .transcribeOnly:
            .sameLanguage
        case .custom:
            nil
        }
    }

    static func apply(_ target: OnboardingTarget, to workflow: inout Workflow) {
        switch target {
        case .sameLanguage:
            guard workflow.kind.isTranscribeOnly == false else { return }
            workflow.kind = .transcribeOnly(cleanup: true)
            if workflow.name == translateName { workflow.name = transcribeName }
        case .language(let language):
            if case .translation(_, let tone, let customTone) = workflow.kind {
                workflow.kind = .translation(targetLanguage: language, tonePreset: tone, customToneText: customTone)
            } else {
                workflow.kind = .translation(targetLanguage: language, tonePreset: .neutral, customToneText: "")
                if workflow.name == transcribeName { workflow.name = translateName }
            }
        }
    }
}
