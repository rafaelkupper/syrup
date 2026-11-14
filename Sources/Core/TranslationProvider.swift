import Foundation

enum TranslationProvider: String, CaseIterable, Identifiable, Sendable, Codable {
    case openAICompatible = "openai_compatible"
    case codexCLI = "codex_cli"
    case appleOnDevice = "apple_on_device"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible:
            "OpenAI-compatible"
        case .codexCLI:
            "Codex CLI"
        case .appleOnDevice:
            "Apple On-Device"
        }
    }

    /// Spoken self-corrections and formatting commands. Apple's on-device model misses them
    /// too often to offer (docs/verification/2026-11-09-model-comparison), so its runs never
    /// ask for them. Other providers depend on the chosen model, so the user opts in.
    var supportsSpokenEdits: Bool { self != .appleOnDevice }

    var latencyHint: String {
        switch self {
        case .openAICompatible:
            "Low latency: direct API request."
        case .codexCLI:
            "Slower: launches the Codex CLI for each translation."
        case .appleOnDevice:
            "Fast and private: runs entirely on this Mac."
        }
    }
}
