import Foundation

/// Words for the Glossary tab's system-voice check. Pure, so it can be tested without a window.
/// Glossary terms and heard forms appear only in the window, never in logs.
enum MishearingCheckCopy {
    typealias TermState = MishearingSuggestionModel.TermState

    /// A term's latest check, shown at the end of its Sounds like cell.
    enum Status: Equatable {
        case checking
        case heard([String])
        case noNewSuggestions
        case heardCorrectly
        case notChecked(String)
        case failed(String)
    }

    /// What a fix for an unavailable language needs.
    enum Fix: Equatable {
        case openSpokenContent
        case openWorkflow(localeID: String)
        case openPrivacy
        case none
    }

    static func status(for state: TermState, locale: Locale = .current) -> Status? {
        switch state {
        case .idle:
            nil
        case .running:
            .checking
        case .results(let result):
            result.heardForms.isEmpty ? .noNewSuggestions : .heard(result.heardForms)
        case .recognizedCorrectly:
            .heardCorrectly
        case .unavailable(let issues):
            .notChecked(notCheckedText(issues, locale: locale))
        case .failed(let failure):
            .failed(failureText(failure))
        }
    }

    /// Short enough for the table. The suggestions themselves are listed under the table.
    static func text(for status: Status) -> String {
        switch status {
        case .checking:
            "Checking…"
        case .heard(let forms):
            forms.count == 1 ? "1 suggestion" : "\(forms.count) suggestions"
        case .noNewSuggestions:
            "Nothing new"
        case .heardCorrectly:
            "Heard correctly"
        case .notChecked:
            "Not checked"
        case .failed:
            "Check failed"
        }
    }

    /// The longer reason, for help text and VoiceOver.
    static func detail(for status: Status) -> String? {
        switch status {
        case .notChecked(let text), .failed(let text):
            text
        case .noNewSuggestions:
            "No new forms to suggest"
        case .checking, .heard, .heardCorrectly:
            nil
        }
    }

    static func notCheckedText(_ issues: [MishearingProbeLocaleIssue], locale: Locale = .current) -> String {
        guard let first = issues.first else { return "Couldn't check" }
        let reason = shortReason(first, locale: locale)
        return issues.count == 1 ? "Couldn't check: \(reason)" : "Couldn't check: \(reason), and more"
    }

    static func failureText(_ failure: MishearingProbeFailure) -> String {
        switch failure {
        case .synthesisFailed:
            "Check failed: the voice couldn't say it"
        case .recognitionFailed:
            "Check failed: dictation couldn't transcribe it"
        case .timedOut:
            "Check took too long"
        case .noUsableSamples:
            "No clear result"
        }
    }

    static func shortReason(_ issue: MishearingProbeLocaleIssue, locale: Locale = .current) -> String {
        let language = languageName(issue.localeID, locale: locale)
        switch issue.reason {
        case .noVoice:
            return "no \(language) voice"
        case .speechModelNotInstalled:
            return "\(language) speech model not installed"
        case .speechPermissionRequired:
            return "Speech Recognition not allowed"
        case .unsupportedLocale:
            return "\(language) not supported"
        }
    }

    /// A full sentence with the way out, shown once per language and reason.
    static func issueText(_ issue: MishearingProbeLocaleIssue, locale: Locale = .current) -> String {
        let language = languageName(issue.localeID, locale: locale)
        switch issue.reason {
        case .noVoice:
            return "No system voice for \(language). Add one in System Settings > Accessibility > Spoken Content."
        case .speechModelNotInstalled:
            return "The \(language) speech model isn't installed. Open a workflow that dictates in \(language) to download it."
        case .speechPermissionRequired:
            return "Speech Recognition isn't allowed yet. Allow it in Privacy."
        case .unsupportedLocale:
            return "Dictation on this Mac can't check \(language)."
        }
    }

    static func fix(for issue: MishearingProbeLocaleIssue) -> Fix {
        switch issue.reason {
        case .noVoice:
            .openSpokenContent
        case .speechModelNotInstalled:
            .openWorkflow(localeID: issue.localeID)
        case .speechPermissionRequired:
            .openPrivacy
        case .unsupportedLocale:
            .none
        }
    }

    /// Every language problem from the latest checks, once each, in the order first seen.
    /// Speech Recognition is one permission, so it appears once whatever the language.
    static func issues(in states: [TermState]) -> [MishearingProbeLocaleIssue] {
        var seen: Set<String> = []
        var issues: [MishearingProbeLocaleIssue] = []
        for state in states {
            let found: [MishearingProbeLocaleIssue]
            switch state {
            case .unavailable(let list):
                found = list
            case .results(let result):
                found = result.unavailableLocales
            case .idle, .running, .recognizedCorrectly, .failed:
                found = []
            }
            for issue in found {
                let key = issue.reason == .speechPermissionRequired
                    ? "permission"
                    : "\(issue.localeID.lowercased())|\(issue.reason)"
                if seen.insert(key).inserted {
                    issues.append(issue)
                }
            }
        }
        return issues
    }

    /// "2 with suggestions, 5 heard correctly", from the latest checks.
    static func summary(of states: [TermState]) -> String? {
        var suggestions = 0
        var correct = 0
        var notChecked = 0
        for state in states {
            switch state {
            case .results(let result) where result.heardForms.isEmpty == false:
                suggestions += 1
            case .recognizedCorrectly:
                correct += 1
            case .unavailable, .failed:
                notChecked += 1
            case .idle, .running, .results:
                break
            }
        }
        let parts = [
            suggestions > 0 ? "\(suggestions) with suggestions" : nil,
            correct > 0 ? "\(correct) heard correctly" : nil,
            notChecked > 0 ? "\(notChecked) not checked" : nil,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// What the check-all row says under its title.
    static func description(localeIDs: [String], isForegroundActive: Bool, locale: Locale = .current) -> String {
        if isForegroundActive {
            return "Not while you dictate. Check again when it's done."
        }
        guard localeIDs.isEmpty == false else {
            return "Needs a voice workflow. Its dictation language is the one checked."
        }
        return "A system voice says each term in \(languageList(localeIDs, locale: locale)), and dictation writes down what it hears."
    }

    static func progressText(_ progress: MishearingSuggestionModel.Progress) -> String {
        progress.total == 1 ? "Checking 1 term…" : "\(progress.done) of \(progress.total)"
    }

    static func languageName(_ localeID: String, locale: Locale = .current) -> String {
        locale.localizedString(forIdentifier: localeID) ?? localeID
    }

    static func languageList(_ localeIDs: [String], locale: Locale = .current) -> String {
        let names = localeIDs.map { languageName($0, locale: locale) }
        switch names.count {
        case 0:
            return ""
        case 1:
            return names[0]
        case 2:
            return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    // MARK: - Everyday words

    static func everydayHelp() -> String {
        "Everyday words. As a hint, they can make the AI change ordinary sentences."
    }

    static func everydayConfirmation(form: String, term: String) -> (message: String, detail: String) {
        (
            "Add “\(form)” as a sounds-like for \(term)?",
            "“\(form)” is made of everyday words. As a hint, it can make the AI rewrite ordinary sentences that use them."
        )
    }

    static func addLabel(form: String, term: String, isEveryday: Bool) -> String {
        isEveryday
            ? "Add everyday words “\(form)” as a sounds-like for \(term)"
            : "Add “\(form)” as a sounds-like for \(term)"
    }

    static func dismissLabel(form: String) -> String {
        "Dismiss “\(form)”"
    }
}
