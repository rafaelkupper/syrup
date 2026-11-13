import Foundation

/// What "Start writing during a pause" can do with the current setup, for the Models tab.
/// It follows the run's rules: normal voice dictation, Apple speech, and a provider that keeps the
/// unfinished transcript on this Mac (Apple On-Device, or an OpenAI-compatible server on a
/// loopback host). Workflow overrides use the server address in Models, as at run time.
/// It reads only settings, never the API key.
struct EarlyTransformationNote: Equatable {
    static let unavailableCue = "This feature only works with Apple On-Device models or a server on this Mac."

    /// False when no voice workflow can start early. The toggle is then disabled and shown off,
    /// and the stored preference is left alone.
    let isAvailable: Bool
    /// One line: the cue when unavailable, or which workflows it reaches.
    let message: String
    /// A second line, when one helps: a blocker other than the provider, or the workflows it skips.
    let detail: String?

    /// What VoiceOver says after the toggle's name.
    var spokenReason: String {
        [message, detail].compactMap(\.self).joined(separator: " ")
    }

    static func make(provider: TranslationProvider, baseURL: String, workflows: [Workflow]) -> Self {
        let candidates = workflows.filter { $0.input == .voice && $0.kind.isTranscribeOnly == false }
        let reached = candidates.filter { reaches($0, provider: provider, baseURL: baseURL) }
        let skipped = candidates.filter { reaches($0, provider: provider, baseURL: baseURL) == false }

        guard reached.isEmpty == false else {
            return Self(
                isAvailable: false,
                message: unavailableCue,
                detail: unavailableDetail(candidates: candidates, provider: provider, baseURL: baseURL)
            )
        }
        return Self(
            isAvailable: true,
            message: reachLine(reached: reached, total: candidates.count),
            detail: skippedLine(skipped, provider: provider, baseURL: baseURL)
        )
    }

    static func keepsDataOnMac(_ provider: TranslationProvider, baseURL: String) -> Bool {
        switch provider {
        case .appleOnDevice:
            true
        case .codexCLI:
            false
        case .openAICompatible:
            URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
                .map(PauseTransformation.isLoopback) ?? false
        }
    }

    private static func reaches(_ workflow: Workflow, provider: TranslationProvider, baseURL: String) -> Bool {
        workflow.speechEngine == .apple && providerKeepsData(workflow, provider: provider, baseURL: baseURL)
    }

    private static func providerKeepsData(_ workflow: Workflow, provider: TranslationProvider, baseURL: String) -> Bool {
        keepsDataOnMac(workflow.translationProvider ?? provider, baseURL: baseURL)
    }

    /// The cue names the provider rule. Say more only when something else is in the way.
    private static func unavailableDetail(candidates: [Workflow], provider: TranslationProvider, baseURL: String) -> String? {
        guard candidates.isEmpty == false else {
            return "It also needs a voice workflow other than Transcribe."
        }
        // Workflows that would work with Apple speech: only the speech model blocks them.
        let speechOnly = candidates.filter { providerKeepsData($0, provider: provider, baseURL: baseURL) }
        guard let first = speechOnly.first else { return nil }
        if speechOnly.count == 1 {
            return "It also needs the Apple speech model. \(first.name) uses \(first.speechEngine.displayName)."
        }
        return "It also needs the Apple speech model. \(speechOnly.count) voice workflows use downloaded models."
    }

    private static func reachLine(reached: [Workflow], total: Int) -> String {
        if reached.count == total {
            return total == 1 ? "Works for your voice workflow." : "Works for all your voice workflows."
        }
        if reached.count <= 3 {
            return "Works for \(reached.map(\.name).formatted(.list(type: .and)))."
        }
        return "Works for \(reached.count) of \(total) voice workflows."
    }

    private static func skippedLine(_ skipped: [Workflow], provider: TranslationProvider, baseURL: String) -> String? {
        guard let first = skipped.first else { return nil }
        if skipped.count == 1 {
            return "Not for \(first.name), which uses \(blocker(of: first, provider: provider, baseURL: baseURL))."
        }
        let usesModel = skipped.contains { $0.speechEngine != .apple }
        let usesProvider = skipped.contains { providerKeepsData($0, provider: provider, baseURL: baseURL) == false }
        let reason = switch (usesModel, usesProvider) {
        case (true, true):
            "a downloaded speech model or a provider that isn't on this Mac"
        case (true, false):
            "a downloaded speech model"
        default:
            "a provider that isn't on this Mac"
        }
        return "Not for the other \(skipped.count), which use \(reason)."
    }

    private static func blocker(of workflow: Workflow, provider: TranslationProvider, baseURL: String) -> String {
        let keepsData = providerKeepsData(workflow, provider: provider, baseURL: baseURL)
        switch (workflow.speechEngine == .apple, keepsData) {
        case (false, true):
            return workflow.speechEngine.displayName
        case (false, false):
            return "\(workflow.speechEngine.displayName) and a provider that isn't on this Mac"
        default:
            return "a provider that isn't on this Mac"
        }
    }
}
