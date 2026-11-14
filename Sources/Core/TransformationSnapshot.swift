import Foundation

/// What a run did with its input, kept with each history record so Retry can rebuild the
/// instruction even after the workflow is edited or deleted.
enum TransformationSnapshot: Equatable, Sendable, Codable {
    case translation(targetLanguage: String, toneInstruction: String)
    case custom(workflowName: String, instruction: String)
    case revision(adjustment: String, instruction: String)
    case contextual(workflowName: String, instruction: String)

    var displayName: String {
        switch self {
        case .translation:
            "Translate"
        case .custom(let workflowName, _):
            workflowName
        case .revision:
            "Revise"
        case .contextual(let workflowName, _):
            workflowName
        }
    }
}
