import SwiftUI

/// The early-start toggle in Models, with a note on which workflows it reaches. When none can use
/// it, the toggle is disabled and shown off, and the stored preference stays as it was.
struct EarlyTransformationSection: View {
    @Bindable var settings: AppSettings

    private static let title = "Start writing during a pause"

    var body: some View {
        let note = note
        Section {
            LabeledContent {
                Toggle(Self.title, isOn: toggleBinding(isAvailable: note.isAvailable))
                    .labelsHidden()
                    .accessibilityHint(note.isAvailable ? "" : note.spokenReason)
            } label: {
                Text(Self.title)
                Text("Starts on what it heard when you pause, and uses it only if the final transcript matches.")
            }
            .disabled(note.isAvailable == false)
            .help(note.isAvailable ? "" : note.message)

            noteRow(note)
        } header: {
            Text("Speed")
        } footer: {
            Text("Revise, Transcribe, and selected text wait for the final transcript.")
                .font(.caption)
        }
    }

    private var note: EarlyTransformationNote {
        EarlyTransformationNote.make(
            provider: settings.translationProvider,
            baseURL: settings.baseURL,
            workflows: settings.workflowList.workflows
        )
    }

    /// Off while unavailable, without writing to the stored preference.
    private func toggleBinding(isAvailable: Bool) -> Binding<Bool> {
        Binding {
            isAvailable && settings.transformsOnPause
        } set: { isOn in
            settings.transformsOnPause = isOn
        }
    }

    private func noteRow(_ note: EarlyTransformationNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: note.isAvailable ? "checkmark.circle" : "info.circle")
                .foregroundStyle(note.isAvailable ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
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
}
