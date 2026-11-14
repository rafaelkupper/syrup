import Foundation

enum TonePreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case neutral
    case professional
    case casual
    case friendly
    case concise
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neutral:
            "Neutral"
        case .professional:
            "Professional"
        case .casual:
            "Casual"
        case .friendly:
            "Friendly"
        case .concise:
            "Concise"
        case .custom:
            "Custom"
        }
    }

    func instruction(customText: String = "") -> String {
        switch self {
        case .neutral:
            ""
        case .professional:
            "Use a professional, workplace-appropriate register."
        case .casual:
            "Use a casual, conversational register."
        case .friendly:
            "Use a warm, friendly register."
        case .concise:
            "Use a concise register and remove unnecessary filler."
        case .custom:
            customText
        }
    }
}
