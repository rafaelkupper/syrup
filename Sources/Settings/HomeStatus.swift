import Foundation

/// What the Home page says, derived from app state so it can be tested without a window.
enum HomeStatus {
    enum Phase: Equatable {
        case idle
        case paused
        case recording
        case transcribing
        case translating
        case error(String)
    }

    enum Tone: Equatable {
        case ok
        case warning
        case bad
        case neutral
    }

    /// `before` and `after` surround the shortcut. `showsShortcut` is false when no key is involved.
    struct Headline: Equatable {
        let before: String
        var after = ""
        var showsShortcut = true
    }

    struct AttentionItem: Identifiable, Equatable {
        enum Severity: Equatable {
            case warning
            case info
        }

        enum Action: Equatable {
            case open(SettingsNavigation.Tab)
            case openActiveWorkflow
            case downloadSpeechModel
            case none
        }

        let message: String
        let severity: Severity
        let action: Action

        var id: String { message }
    }

    struct Inputs {
        var microphone = PermissionStatusModel.Status.unknown
        var speech = PermissionStatusModel.Status.unknown
        var accessibility = PermissionStatusModel.Status.unknown
        var autoPasteEnabled = false
        var usesVoice = true
        var localeState = TranscriberAssetManager.AssetState.unknown
        var localeMessage = ""
        var speechModelName: String?
        var speechModelState = SpeechModelState.notDownloaded
        var providerSetupMessage: String?
        var glossarySuggestionCount = 0
    }

    static func status(phase: Phase, items: [AttentionItem]) -> (text: String, tone: Tone) {
        switch phase {
        case .paused:
            ("Paused", .neutral)
        case .recording:
            ("Recording", .bad)
        case .transcribing:
            ("Transcribing", .ok)
        case .translating:
            ("Translating", .ok)
        case .error:
            ("Something went wrong", .bad)
        case .idle:
            items.contains { $0.severity == .warning } ? ("Needs attention", .warning) : ("Ready", .ok)
        }
    }

    static func headline(
        phase: Phase,
        input: WorkflowInput,
        mode: HotkeyMode,
        hasShortcut: Bool,
        isFnLatched: Bool = false
    ) -> Headline {
        switch phase {
        case .recording where isFnLatched:
            return Headline(before: "Listening. Double-tap Fn to finish", showsShortcut: false)
        case .paused:
            return Headline(before: "The hotkey is paused", showsShortcut: false)
        case .recording where mode == .hold:
            return Headline(before: "Listening. Release", after: "to finish")
        case .recording:
            return Headline(before: "Listening. Press", after: "to finish")
        case .transcribing:
            return Headline(before: "Transcribing…", showsShortcut: false)
        case .translating:
            return Headline(before: "Working on it…", showsShortcut: false)
        case .error(let message):
            return Headline(before: message, showsShortcut: false)
        case .idle:
            guard hasShortcut else {
                return Headline(before: "Set a shortcut to start dictating", showsShortcut: false)
            }
            if input == .selection {
                return Headline(before: "Select text, then press")
            }
            return Headline(before: mode == .hold ? "Hold" : "Press", after: "and speak")
        }
    }

    static func outcome(kind: WorkflowKind, pastes: Bool) -> String {
        let delivery = pastes ? "pastes it where your cursor is." : "copies it to the clipboard."
        return switch kind {
        case .translation:
            "Syrup translates it and \(delivery)"
        case .custom:
            "Syrup follows this workflow’s instruction and \(delivery)"
        case .transcribeOnly:
            "Syrup writes down what you said and \(delivery)"
        }
    }

    static func attentionItems(_ inputs: Inputs) -> [AttentionItem] {
        var items: [AttentionItem] = []
        if inputs.usesVoice {
            if inputs.microphone.needsAttention {
                items.append(AttentionItem(message: "Syrup needs Microphone access to record", severity: .warning, action: .open(.privacy)))
            }
            if inputs.speech.needsAttention {
                items.append(AttentionItem(message: "Syrup needs Speech Recognition access to transcribe", severity: .warning, action: .open(.privacy)))
            }
        }
        if inputs.autoPasteEnabled, inputs.accessibility.needsAttention {
            items.append(AttentionItem(message: "Pasting is off until Accessibility is allowed", severity: .warning, action: .open(.privacy)))
        }
        if inputs.usesVoice {
            switch inputs.localeState {
            case .unsupported, .failed:
                items.append(AttentionItem(message: inputs.localeMessage, severity: .warning, action: .openActiveWorkflow))
            case .downloading:
                items.append(AttentionItem(message: inputs.localeMessage, severity: .info, action: .none))
            case .unknown, .checking, .installed:
                break
            }
        }
        if inputs.usesVoice, let name = inputs.speechModelName {
            switch inputs.speechModelState {
            case .notDownloaded:
                items.append(AttentionItem(message: "This workflow uses Apple speech until \(name) is downloaded", severity: .info, action: .downloadSpeechModel))
            case .downloading:
                items.append(AttentionItem(message: "Downloading \(name)", severity: .info, action: .none))
            case .failed:
                items.append(AttentionItem(message: "\(name) isn’t available, so this workflow uses Apple speech", severity: .warning, action: .openActiveWorkflow))
            case .unsupported, .downloaded, .loading, .ready:
                break
            }
        }
        if let message = inputs.providerSetupMessage {
            items.append(AttentionItem(message: message, severity: .warning, action: .open(.models)))
        }
        if inputs.glossarySuggestionCount > 0 {
            let count = inputs.glossarySuggestionCount
            let message = count == 1 ? "1 glossary suggestion is ready to review" : "\(count) glossary suggestions are ready to review"
            items.append(AttentionItem(message: message, severity: .info, action: .open(.glossary)))
        }
        return items
    }

    /// Where a run's text goes for the default provider. Nil means it stays on this Mac.
    static func destination(provider: TranslationProvider, baseURL: String) -> String? {
        switch provider {
        case .appleOnDevice:
            nil
        case .codexCLI:
            "OpenAI, through Codex CLI"
        case .claudeCLI:
            "Anthropic, through Claude Code"
        case .openAICompatible:
            URL(string: baseURL)?.host() ?? "Your OpenAI-compatible endpoint"
        }
    }

    static func durationLabel(_ seconds: TimeInterval) -> String {
        "\(seconds.formatted(.number.precision(.fractionLength(1)))) s"
    }
}

extension Workflow {
    /// One line for the workflow list.
    @MainActor var summary: String {
        let language = TranscriberAssetManager.displayName(for: Locale(identifier: dictationLocaleID))
        let source = switch input {
        case .voice:
            includeSelectionContext ? "Voice + selected text" : "Voice"
        case .selection:
            "Selected text"
        }
        return switch kind {
        case .translation(let targetLanguage, _, _):
            input == .voice && includeSelectionContext == false
                ? "\(source) · \(language) → \(targetLanguage)"
                : "\(source) → \(targetLanguage)"
        case .custom:
            "\(source) · Custom instruction"
        case .transcribeOnly:
            "\(source) · \(language) · No AI, stays on this Mac"
        }
    }
}
