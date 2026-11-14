import SwiftUI

/// One listed model. Outside the view so it is not tied to the main actor.
struct CLIModelChoice: Identifiable, Equatable, Sendable {
    let id: String
    let title: String

    /// A saved name that is neither the default nor in the list shows as custom, so it stays visible
    /// and editable instead of silently looking like another choice.
    static func isCustom(_ model: String, in choices: [CLIModelChoice]) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty == false && choices.contains { $0.id == trimmed } == false
    }
}

/// A model choice for a command-line provider: the tool's own default, the listed models, or a custom
/// name. With no list (the catalog could not be read), it is just a text field.
struct CLIModelPicker: View {
    typealias Choice = CLIModelChoice

    let defaultTitle: String
    let choices: [Choice]?
    @Binding var model: String
    @State private var choosesCustom = false

    private static let customTag = "\u{1}custom"

    var body: some View {
        LabeledContent("Model") {
            VStack(alignment: .trailing, spacing: 6) {
                if let choices {
                    Picker("Model", selection: selection(choices)) {
                        Text(defaultTitle).tag("")
                        ForEach(choices) { Text($0.title).tag($0.id) }
                        Divider()
                        Text("Custom…").tag(Self.customTag)
                    }
                    .labelsHidden()
                    .frame(width: 260)
                }
                if choices == nil || showsCustomField(choices ?? []) {
                    TextField("Model name", text: $model, prompt: Text(choices == nil ? defaultTitle : "Model name"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
            }
        }
    }

    private func showsCustomField(_ choices: [Choice]) -> Bool {
        choosesCustom || CLIModelChoice.isCustom(model, in: choices)
    }

    private func selection(_ choices: [Choice]) -> Binding<String> {
        Binding {
            showsCustomField(choices) ? Self.customTag : model
        } set: { value in
            if value == Self.customTag {
                choosesCustom = true
            } else {
                choosesCustom = false
                model = value
            }
        }
    }

}
