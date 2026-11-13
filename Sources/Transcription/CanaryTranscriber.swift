import AVFoundation
import Foundation

protocol CanaryDecoding: Sendable {
    var windowSamples: Int { get async }
    func transcribe(_ samples: [Float], language: String) async throws -> String
}

/// Owns the loaded Canary model. Core ML predictions run on this actor, one window at a time.
actor CanaryEngine: CanaryDecoding {
    private var model: CanaryModel?

    var windowSamples: Int { model?.windowSamples ?? 160_000 }

    func load(from directory: URL) throws {
        guard model == nil else { return }
        let model = try CanaryModel(directory: directory)
        _ = try model.transcribe([Float](repeating: 0, count: 16_000), language: "en")
        self.model = model
    }

    func unload() {
        model = nil
    }

    func transcribe(_ samples: [Float], language: String) throws -> String {
        guard let model else { throw ParakeetError.notLoaded }
        return try model.transcribeRecovering(samples, language: language)
    }
}

/// Canary sees 10 seconds at a time, so longer dictations are cut at the quietest
/// moment of each window's last 4 seconds, and each piece is decoded while recording continues.
struct CanaryTranscriber: Transcriber {
    static let pauseSearch = SpeechSegmenter.samples(milliseconds: 4_000)
    private let decoder: any CanaryDecoding

    init(decoder: any CanaryDecoding) {
        self.decoder = decoder
    }

    func transcribe(
        _ audio: AudioBufferSequence,
        locale: Locale,
        vocabulary: [String],
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) async throws -> String {
        guard let language = SpeechEngine.languageCode(for: locale.identifier),
              CanaryModel.languages.contains(language) else { throw CanaryError.unsupportedLanguage }
        let window = await decoder.windowSamples
        var converter = AnalyzerAudioConverter(targetFormat: ParakeetTranscriber.format)
        var pending: [Float] = []
        var texts: [String] = []
        for try await buffer in audio {
            try Task.checkCancellation()
            Self.append(try converter.convert(buffer), to: &pending)
            try await decodeFullWindows(&pending, window: window, language: language, into: &texts)
        }
        for buffer in try converter.finish() {
            Self.append(buffer, to: &pending)
        }
        try await decodeFullWindows(&pending, window: window, language: language, into: &texts)
        try Task.checkCancellation()
        texts.append(try await decode(pending, language: language))
        return texts.filter { $0.isEmpty == false }.joined(separator: " ")
    }

    private func decodeFullWindows(_ pending: inout [Float], window: Int, language: String, into texts: inout [String]) async throws {
        while pending.count > window {
            let piece = Array(pending[..<window])
            let cut = SpeechSegmenter.pauseCut(in: piece, search: Self.pauseSearch, force: true) ?? window
            texts.append(try await decode(Array(pending[..<cut]), language: language))
            pending.removeFirst(cut)
        }
    }

    private func decode(_ samples: [Float], language: String) async throws -> String {
        guard SpeechSegmenter.containsSpeech(samples) else { return "" }
        return try await decoder.transcribe(samples, language: language)
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
