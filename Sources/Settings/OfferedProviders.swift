import Foundation

extension AppSettings {
    /// Providers to offer in pickers and retry menus. Claude Code is listed only when it is installed or
    /// something already uses it, so people without it never see a choice that cannot work.
    func offeredProviders(claudeInstalled: Bool? = nil) -> [TranslationProvider] {
        let offersClaude = isClaudeCodeOffered(claudeInstalled: claudeInstalled)
        return TranslationProvider.allCases.filter { $0 != .claudeCLI || offersClaude }
    }

    var isClaudeCodeOffered: Bool { isClaudeCodeOffered(claudeInstalled: nil) }

    /// `claudeInstalled` is for tests; nil looks on disk.
    func isClaudeCodeOffered(claudeInstalled: Bool?) -> Bool {
        translationProvider == .claudeCLI
            || workflowList.workflows.contains { $0.translationProvider == .claudeCLI }
            || claudeInstalled ?? ClaudeCLIConfigurationResolver.isInstalled(configuredPath: claudePath)
    }
}
