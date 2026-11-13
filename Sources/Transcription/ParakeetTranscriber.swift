import AVFoundation
import Foundation

protocol ParakeetDecoding: Sendable {
    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String
}

extension ParakeetEngine: ParakeetDecoding {}

struct ParakeetTranscriber: Transcriber {
    static let sampleRate = 16_000
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false)!
    static let shortestDecode = samples(milliseconds: 500)
    private static let wholeDecodeLimit = samples(milliseconds: 60_000)
    private static let pauseSearch = samples(milliseconds: 15_000)
    private static let longestDecode = wholeDecodeLimit + pauseSearch

    private let decoder: any ParakeetDecoding

    init(decoder: any ParakeetDecoding) {
        self.decoder = decoder
    }

    func transcribe(
        _ audio: AudioBufferSequence,
        locale: Locale,
        vocabulary: [String],
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let languageCode = SpeechEngine.languageCode(for: locale.identifier)
        var converter = AnalyzerAudioConverter(targetFormat: Self.format)
        var pending: [Float] = []
        pending.reserveCapacity(Self.longestDecode + 8_192)
        var texts: [String] = []
        for try await buffer in audio {
            try Task.checkCancellation()
            Self.append(try converter.convert(buffer), to: &pending)
            if pending.count >= Self.wholeDecodeLimit,
               let cut = Self.pauseCut(in: pending, force: pending.count >= Self.longestDecode) {
                texts.append(try await decode(Array(pending[..<cut]), languageCode: languageCode))
                pending.removeFirst(cut)
            }
        }
        for buffer in try converter.finish() {
            Self.append(buffer, to: &pending)
        }
        try Task.checkCancellation()
        texts.append(try await decode(pending, languageCode: languageCode))
        return texts.filter { $0.isEmpty == false }.joined(separator: " ")
    }

    private func decode(_ samples: [Float], languageCode: String?) async throws -> String {
        guard Self.containsSpeech(samples) else { return "" }
        let padding = Self.shortestDecode - samples.count
        return try await decoder.transcribe(padding > 0 ? samples + repeatElement(0, count: padding) : samples, languageCode: languageCode)
    }

    /// Parakeet invents short words such as "Yeah." for audio without speech.
    private static func containsSpeech(_ samples: [Float]) -> Bool {
        SpeechSegmenter.containsSpeech(samples)
    }

    /// Each Parakeet decode ends its text as a finished sentence, so a cut mid-sentence adds a
    /// false period and capital.
    private static func pauseCut(in samples: [Float], force: Bool) -> Int? {
        SpeechSegmenter.pauseCut(in: samples, search: pauseSearch, force: force)
    }

    private static func samples(milliseconds: Int) -> Int {
        sampleRate * milliseconds / 1_000
    }

    private static func append(_ buffer: AVAudioPCMBuffer, to samples: inout [Float]) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
