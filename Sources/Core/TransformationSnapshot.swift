import Foundation

/// What a run did with its input, kept with each history record so Retry can rebuild the
/// instruction even after the workflow is edited or deleted.
enum TransformationSnapshot: Equatable, Sendable, Codable {
    case translation(targetLanguage: String, toneInstruction: String)
    /// `instruction` is the rendered prompt the run sent. `prompt` keeps the workflow's own parts, so
    /// Retry composes them again with the current glossary; records from older builds lack it.
    case custom(workflowName: String, instruction: String, prompt: CustomPrompt? = nil)
    /// Retry composes the instruction again from `adjustment`; `instruction` is what the run sent.
    case revision(adjustment: String, instruction: String)
    case contextual(workflowName: String, instruction: String)

    /// A custom workflow's instruction and output-contract choice, without the glossary.
    struct CustomPrompt: Equatable, Sendable, Codable {
        let base: String
        let enforcesOutputContract: Bool
    }

    var displayName: String {
        switch self {
        case .translation:
            "Translate"
        case .custom(let workflowName, _, _):
            workflowName
        case .revision:
            "Revise"
        case .contextual(let workflowName, _):
            workflowName
        }
    }
}
