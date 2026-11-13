import AVFoundation
import Foundation

protocol Transcriber: Sendable {
    /// Transcribes the audio stream, reporting the running "heard so far" text
    /// (finalized + latest volatile segment) through `onPartialTranscript` as
    /// recognition progresses. Callers that don't need live feedback pass nil.
    func transcribe(
        _ audio: AudioBufferSequence,
        locale: Locale,
        vocabulary: [String],
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) async throws -> String
    func transcribe(
        _ audio: AudioBufferSequence, locale: Locale, vocabulary: [String],
        onPartialTranscript: (@Sendable (String) -> Void)?, preferFastResults: Bool
    ) async throws -> String
}

extension Transcriber {
    func transcribe(
        _ audio: AudioBufferSequence, locale: Locale, vocabulary: [String],
        onPartialTranscript: (@Sendable (String) -> Void)?, preferFastResults: Bool
    ) async throws -> String {
        try await transcribe(audio, locale: locale, vocabulary: vocabulary, onPartialTranscript: onPartialTranscript)
    }
}
