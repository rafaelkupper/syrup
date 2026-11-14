import AVFoundation
import Foundation

/// Everything a transcriber needs besides the audio. New options belong here, not in new
/// `transcribe` overloads.
struct TranscriptionRequest: Sendable {
    var locale: Locale
    var vocabulary: [String] = []
    /// Receives the running "heard so far" text (finalized plus the latest volatile segment) as
    /// recognition progresses. Callers that don't need live feedback leave it nil.
    var onPartialTranscript: (@Sendable (String) -> Void)? = nil
    /// Lets an engine trade some accuracy for latency. Apple's SpeechTranscriber honors it; engines
    /// without such a mode ignore it.
    var preferFastResults = false
}

protocol Transcriber: Sendable {
    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String
}
