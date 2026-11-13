import SwiftUI

/// The workflow read as one sentence, where each choice is a menu.
/// "Hear Portuguese (Brazil) with Apple, translate to English in a Neutral tone, then paste it."
struct WorkflowSentence: View {
    let bindings: WorkflowBindings
    var showsProvider = false
    /// Called when the sentence turns pasting on, so the caller can ask for Accessibility.
    var onPasteEnabled: () -> Void = {}

    private var workflow: Workflow { bindings.workflow }

    var body: some View {
        FlowLayout(spacing: 5, lineSpacing: 5) {
            inputWords
            Text(",").attachesToPrevious()
            actionWords
            if showsProvider, workflow.kind.isTranscribeOnly == false {
                words("using")
                providerMenu
            }
            Text(",").attachesToPrevious()
            words("then")
            deliveryMenu
            Text(".").attachesToPrevious()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("What this workflow does")
    }

    @ViewBuilder
    private var inputWords: some View {
        switch workflow.input {
        case .voice:
            words("Hear")
            SentenceMenu(
                title: "Dictation language",
                label: bindings.localeName,
                selection: bindings.dictationLocale,
                choices: bindings.dictationLocaleChoices
            )
            words("with")
            speechModelMenu
            if workflow.includeSelectionContext, workflow.kind.isTranscribeOnly == false {
                words("plus the selected text")
            }
        case .selection:
            words("Take the selected text")
        }
    }

    @ViewBuilder
    private var actionWords: some View {
        switch workflow.kind {
        case .translation(_, let tone, _):
            words("translate to")
            SentenceMenu(
                title: "Translate to",
                label: bindings.targetLanguage.wrappedValue,
                selection: bindings.targetLanguage,
                choices: bindings.targetLanguageChoices
            )
            words("in a")
            SentenceMenu(
                title: "Tone",
                label: tone.displayName,
                selection: bindings.tonePreset,
                choices: TonePreset.allCases.map { MenuChoice(value: $0, title: $0.displayName) }
            )
            words("tone")
        case .custom:
            words("follow its instruction")
        case .transcribeOnly(let cleanup, _):
            words("write it down")
            SentenceMenu(
                title: "Clean up",
                label: cleanup ? "cleaned up" : "word for word",
                selection: bindings.cleanup,
                choices: [MenuChoice(value: true, title: "cleaned up"), MenuChoice(value: false, title: "word for word")]
            )
        }
    }

    private var speechModelMenu: some View {
        let engine = workflow.speechEngine
        let state = bindings.speechModels.manager(for: engine)?.state
        let waiting = state != nil && state != .ready && state != .downloaded
        return SentenceMenu(
            title: "Speech model",
            label: engine.displayName,
            selection: bindings.speechEngine,
            tint: waiting ? .orange : .accentColor,
            choices: bindings.availableSpeechEngines.map { MenuChoice(value: $0, title: $0.displayName) }
        )
        .help(waiting ? "Apple speech is used until \(engine.displayName) is downloaded" : engine.tagline)
    }

    private var providerMenu: some View {
        SentenceMenu(
            title: "AI provider",
            label: bindings.effectiveProvider.displayName,
            selection: bindings.providerOverride,
            choices: bindings.providerChoices
        )
    }

    private var deliveryMenu: some View {
        SentenceMenu(
            title: "Delivery",
            label: bindings.pastesResult.wrappedValue ? "paste it" : "copy it",
            selection: Binding {
                bindings.pastesResult.wrappedValue
            } set: { pastes in
                bindings.pastesResult.wrappedValue = pastes
                if pastes { onPasteEnabled() }
            },
            choices: [MenuChoice(value: true, title: "paste it"), MenuChoice(value: false, title: "copy it")]
        )
        .help("Results always reach the clipboard. Pasting applies to every workflow.")
    }

    /// One view per word, so the sentence wraps between words.
    private func words(_ phrase: String) -> some View {
        ForEach(Array(phrase.split(separator: " ").enumerated()), id: \.offset) { _, word in
            Text(word)
        }
    }
}
