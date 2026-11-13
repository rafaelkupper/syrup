import AVFoundation
import Foundation
import Testing
@testable import Syrup

struct ParakeetTranscriberTests {
    @Test func dictationsUpToAMinuteDecodeOnceEvenAcrossPauses() async throws {
        let samples = paused(syllables(59 * 16_000), atSeconds: [12, 26, 45])
        let decoder = SegmentRecorder()
        let text = try await ParakeetTranscriber(decoder: decoder)
            .transcribe(try stream(samples), locale: Locale(identifier: "pt-BR"), vocabulary: [], onPartialTranscript: nil)
        #expect(text == "segment 1")
        #expect(await decoder.segments.map(\.count) == [samples.count])
        #expect(await decoder.languageCodes == ["pt"])
    }

    @Test func longerDictationsAreCutInsideARealPause() async throws {
        let samples = paused(syllables(100 * 16_000), atSeconds: [55])
        let segments = try await segmentLengths(samples)
        #expect(segments.count == 2)
        #expect(abs((segments.first ?? 0) - 55 * 16_000) <= 3_200)
        #expect(segments.reduce(0, +) == samples.count)
    }

    @Test func withoutAPauseNoCutComesBeforeAMinuteAndNoDecodeExceeds75Seconds() async throws {
        let samples = syllables(160 * 16_000)
        let segments = try await segmentLengths(samples)
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0 <= 75 * 16_000 })
        #expect(segments.dropLast().allSatisfy { $0 > 60 * 16_000 })
        #expect(segments.reduce(0, +) == samples.count)
    }

    @Test func aShortRecordingIsPaddedToTheShortestDecodableLength() async throws {
        let decoder = SegmentRecorder()
        let speech = syllables(3_200)
        _ = try await ParakeetTranscriber(decoder: decoder)
            .transcribe(try stream(speech), locale: Locale(identifier: "en-US"), vocabulary: [], onPartialTranscript: nil)
        let segment = try #require(await decoder.segments.first)
        #expect(segment.count == ParakeetTranscriber.shortestDecode)
        #expect(Array(segment.prefix(3_200)) == speech)
    }

    @Test(arguments: [Float(0), 0.0006, 0.002, 0.006, 0.02])
    func roomNoiseWithoutSpeechIsNeverDecoded(level: Float) async throws {
        let decoder = SegmentRecorder()
        let text = try await ParakeetTranscriber(decoder: decoder)
            .transcribe(try stream(noise(16_000, level: level)), locale: Locale(identifier: "pt-BR"), vocabulary: [], onPartialTranscript: nil)
        #expect(text.isEmpty)
        #expect(await decoder.segments.isEmpty)
    }

    @Test func aShortWordTenDecibelsAboveRoomNoiseIsDecoded() async throws {
        let word = 6_400..<9_600
        let samples = noise(16_000, level: 0.002).enumerated().map { index, sample in
            word.contains(index) ? sample + 0.0089 * sin(Float(index) * 0.15) : sample
        }
        let decoder = SegmentRecorder()
        let text = try await ParakeetTranscriber(decoder: decoder)
            .transcribe(try stream(samples), locale: Locale(identifier: "pt-BR"), vocabulary: [], onPartialTranscript: nil)
        #expect(text == "segment 1")
    }

    @Test func roomNoiseLeftAfterTheLastCutAddsNoWords() async throws {
        let speechEnd = 59_300 * 16
        let speech = syllables(speechEnd)
        let samples = noise(61 * 16_000, level: 0.002).enumerated().map { index, sample in
            index < speechEnd ? sample + speech[index] : sample
        }
        let decoder = SegmentRecorder()
        let text = try await ParakeetTranscriber(decoder: decoder)
            .transcribe(try stream(samples), locale: Locale(identifier: "pt-BR"), vocabulary: [], onPartialTranscript: nil)
        #expect(text == "segment 1")
        #expect(try #require(await decoder.segments.first).count >= speechEnd)
    }

    private func segmentLengths(_ samples: [Float]) async throws -> [Int] {
        let decoder = SegmentRecorder()
        _ = try await ParakeetTranscriber(decoder: decoder)
            .transcribe(try stream(samples), locale: Locale(identifier: "pt-BR"), vocabulary: [], onPartialTranscript: nil)
        return await decoder.segments.map(\.count)
    }

    private func paused(_ samples: [Float], atSeconds seconds: [Int]) -> [Float] {
        samples.indices.map { index in
            seconds.contains { abs(index - $0 * 16_000) < 3_200 } ? 0 : samples[index]
        }
    }

    private func syllables(_ count: Int) -> [Float] {
        (0..<count).map { index in
            (index / 2_400).isMultiple(of: 2) ? 0.2 * sin(Float(index) * 0.15) : 0
        }
    }

    private func noise(_ count: Int, level: Float) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return (Float(state >> 40) / Float(1 << 24) * 2 - 1) * level * 1.732
        }
    }

    private func stream(_ samples: [Float]) throws -> AudioBufferSequence {
        let (stream, continuation) = AudioBufferSequence.makeStream()
        for start in stride(from: 0, to: samples.count, by: 4_096) {
            let count = min(4_096, samples.count - start)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: ParakeetTranscriber.format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            samples[start..<(start + count)].withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: count)
            }
            continuation.yield(buffer)
        }
        continuation.finish()
        return stream
    }
}

private actor SegmentRecorder: ParakeetDecoding {
    private(set) var segments: [[Float]] = []
    private(set) var languageCodes: [String?] = []

    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String {
        segments.append(samples)
        languageCodes.append(languageCode)
        return "segment \(segments.count)"
    }
}
