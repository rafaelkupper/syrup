import Foundation

enum WorkflowKind: Equatable, Sendable, Codable {
    case translation(targetLanguage: String, tonePreset: TonePreset, customToneText: String)
    case custom(instruction: String, enforceOutputContract: Bool)
    case transcribeOnly(cleanup: Bool, spokenSymbols: Bool = false)

    private enum CodingKeys: String, CodingKey { case translation, custom, transcribeOnly }
    private enum OptionKeys: String, CodingKey {
        case targetLanguage, tonePreset, customToneText, instruction, enforceOutputContract, cleanup, spokenSymbols
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one workflow kind"))
        }
        let options = try container.nestedContainer(keyedBy: OptionKeys.self, forKey: key)
        switch key {
        case .translation:
            self = .translation(targetLanguage: try options.decode(String.self, forKey: .targetLanguage),
                                tonePreset: try options.decode(TonePreset.self, forKey: .tonePreset),
                                customToneText: try options.decode(String.self, forKey: .customToneText))
        case .custom:
            self = .custom(instruction: try options.decode(String.self, forKey: .instruction),
                           enforceOutputContract: try options.decode(Bool.self, forKey: .enforceOutputContract))
        case .transcribeOnly:
            self = .transcribeOnly(cleanup: try options.decode(Bool.self, forKey: .cleanup),
                                   spokenSymbols: try options.decodeIfPresent(Bool.self, forKey: .spokenSymbols) ?? false)
        }
    }

    var isTranscribeOnly: Bool {
        switch self {
        case .translation, .custom: false
        case .transcribeOnly: true
        }
    }
}

import Foundation

protocol TextTransformer: Sendable {
    func transform(_ text: String, instruction: String) async throws -> String
}

protocol StreamingTextTransformer: TextTransformer {
    /// Yields append-only text fragments and then finishes.
    func transformStream(
        _ text: String,
        instruction: String
    ) -> AsyncThrowingStream<String, any Error>

    /// Starts a clean atomic generation after a stream cannot remain append-only.
    func transformAfterStreamingFallback(
        _ text: String,
        instruction: String
    ) async throws -> String
}

extension StreamingTextTransformer {
    func transformAfterStreamingFallback(
        _ text: String,
        instruction: String
    ) async throws -> String {
        try await transform(text, instruction: instruction)
    }
}
