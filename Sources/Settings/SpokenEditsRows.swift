import SwiftUI

/// What the spoken-edit toggles can do with a workflow's provider. Apple's on-device model
/// misses self-corrections and formatting commands too often, so they're off for it; other
/// providers depend on the chosen model, so they're opt-in with a recommendation.
/// See docs/verification/2026-11-09-model-comparison. Reads only settings, never the API key.
struct SpokenEditsNote: Equatable {
    enum Tone: Equatable { case unavailable, caution, recommended }

    static let recommendedModel = "gpt-oss-120b"
    static let recommendedHost = "api.cerebras.ai"
    static let recommendation = "We recommend \(recommendedModel) on Cerebras."
    static let unavailableCue = "Apple’s on-device model can’t do these reliably, so they’re off."

    /// False for Apple On-Device: the toggles are disabled and shown off, and the stored
    /// preferences stay as they were for workflows that use another provider.
    let isAvailable: Bool
    let tone: Tone
    let message: String
    let detail: String?

    var spokenReason: String {
        [message, detail].compactMap(\.self).joined(separator: " ")
    }

    /// Nil when there's nothing to say (Codex CLI runs a capable model).
    static func make(provider: TranslationProvider, baseURL: String, modelName: String) -> Self? {
        switch provider {
        case .appleOnDevice:
            Self(
                isAvailable: false,
                tone: .unavailable,
                message: unavailableCue,
                detail: "To use them, choose an OpenAI-compatible provider for this workflow. \(recommendation)"
            )
        case .openAICompatible where usesRecommendedModel(baseURL: baseURL, modelName: modelName):
            Self(
                isAvailable: true,
                tone: .recommended,
                message: "You’re using \(recommendedModel) on Cerebras, the model we recommend for these.",
                detail: nil
            )
        case .openAICompatible:
            Self(
                isAvailable: true,
                tone: .caution,
                message: "Advanced: these need a capable model, or they can change what you said. \(recommendation)",
                detail: nil
            )
        case .codexCLI, .claudeCLI:
            nil
        }
    }

    static func usesRecommendedModel(baseURL: String, modelName: String) -> Bool {
        let host = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host()?.lowercased()
        return host == recommendedHost
            && modelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == recommendedModel
    }
}

/// The two spoken-edit toggles in a voice Translate workflow, gated by its provider.
struct SpokenEditsRows: View {
    @Bindable var settings: AppSettings
    let provider: TranslationProvider

    var body: some View {
        let note = SpokenEditsNote.make(provider: provider, baseURL: settings.baseURL, modelName: settings.modelName)
        let isAvailable = note?.isAvailable ?? true

        Group {
            LabeledContent {
                Toggle("Handle self-corrections", isOn: binding(\.handlesSelfCorrections, isAvailable: isAvailable))
                    .labelsHidden()
                    .accessibilityHint(isAvailable ? "" : note?.spokenReason ?? "")
            } label: {
                Text("Handle self-corrections")
                Text("“at 3, no wait, 4” becomes “at 4”, and “um” and “hmm” are dropped")
            }
            LabeledContent {
                Toggle("Follow formatting commands", isOn: binding(\.handlesSpokenFormatting, isAvailable: isAvailable))
                    .labelsHidden()
                    .accessibilityHint(isAvailable ? "" : note?.spokenReason ?? "")
            } label: {
                Text("Follow formatting commands")
                Text("“new line”, “new paragraph”, “make a list”, “numbered list”, “in quotes”, “open quote”, “period”, “comma”, “question mark”")
            }
        }
        .disabled(isAvailable == false)
        .help(isAvailable ? "" : note?.message ?? "")

        if let note {
            noteRow(note)
        }
    }

    /// Off while unavailable, without writing to the stored preference.
    private func binding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>, isAvailable: Bool) -> Binding<Bool> {
        Binding {
            isAvailable && settings[keyPath: keyPath]
        } set: { isOn in
            settings[keyPath: keyPath] = isOn
        }
    }

    private func noteRow(_ note: SpokenEditsNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol(for: note.tone))
                .foregroundStyle(color(for: note.tone))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.message)
                if let detail = note.detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func symbol(for tone: SpokenEditsNote.Tone) -> String {
        switch tone {
        case .unavailable: "info.circle"
        case .caution: "exclamationmark.triangle"
        case .recommended: "checkmark.circle"
        }
    }

    private func color(for tone: SpokenEditsNote.Tone) -> AnyShapeStyle {
        switch tone {
        case .unavailable: AnyShapeStyle(.secondary)
        case .caution: AnyShapeStyle(.orange)
        case .recommended: AnyShapeStyle(.green)
        }
    }
}
