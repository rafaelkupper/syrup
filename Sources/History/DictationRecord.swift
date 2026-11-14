import Foundation

struct DictationRecord: Identifiable, Equatable, Sendable, Codable {
    enum Outcome: Equatable, Sendable, Codable {
        case success
        case failed(message: String)
    }

    typealias TransformationSnapshot = Syrup.TransformationSnapshot

    let id: UUID
    let finishedAt: Date
    let transcript: String
    let output: String?
    let transformation: TransformationSnapshot
    let outcome: Outcome
    let provider: TranslationProvider?
    /// Seconds from releasing the hotkey to the clipboard write. Nil for runs without a release, and for history saved by older builds.
    let duration: TimeInterval?

    init(
        id: UUID,
        finishedAt: Date,
        transcript: String,
        output: String?,
        transformation: TransformationSnapshot,
        outcome: Outcome,
        provider: TranslationProvider? = nil,
        duration: TimeInterval? = nil
    ) {
        self.id = id
        self.finishedAt = finishedAt
        self.transcript = transcript
        self.output = output
        self.transformation = transformation
        self.outcome = outcome
        self.provider = provider
        self.duration = duration
    }

    var canUseTranscriptFallback: Bool {
        guard case .failed = outcome else { return false }

        return switch transformation {
        case .revision, .contextual:
            false
        case .translation, .custom:
            true
        }
    }

    var canRetry: Bool {
        guard case .failed = outcome else { return false }

        return switch transformation {
        case .contextual: false
        case .translation, .custom, .revision: true
        }
    }

    var canCopyFromHistory: Bool {
        if case .failed = outcome, case .contextual = transformation {
            false
        } else {
            true
        }
    }

    var canRetryWithOriginalProvider: Bool {
        canRetry && provider != nil
    }
}

extension DictationRecord {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        finishedAt = try container.decode(Date.self, forKey: .finishedAt)
        transcript = try container.decode(String.self, forKey: .transcript)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        transformation = try container.decode(TransformationSnapshot.self, forKey: .transformation)
        outcome = try container.decode(Outcome.self, forKey: .outcome)
        provider = try container.decodeProviderIfPresent(forKey: .provider)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
    }
}

/// Decodes one history record, or nil when this build cannot read it, so one record never costs
/// the whole file.
struct LossyDictationRecord: Decodable {
    let record: DictationRecord?

    init(from decoder: any Decoder) throws {
        record = try? DictationRecord(from: decoder)
    }
}
