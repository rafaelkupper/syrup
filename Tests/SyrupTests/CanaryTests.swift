import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Syrup

private actor FakeCanary: CanaryDecoding {
    let windowSamples: Int
    private(set) var segments: [Int] = []
    private(set) var languages: [String] = []

    init(windowSamples: Int = 160_000) {
        self.windowSamples = windowSamples
    }

    func transcribe(_ samples: [Float], language: String) async throws -> String {
        segments.append(samples.count)
        languages.append(language)
        return "part\(segments.count)"
    }
}

struct CanaryTests {
    /// Tone bursts with short gaps, like words separated by pauses.
    private func speechLike(seconds: Double) -> [Float] {
        let count = Int(seconds * 16_000)
        return (0..<count).map { index in
            let inWord = (index / 4_000) % 4 != 3
            return inWord ? 0.3 * sin(Float(index) * 0.2) : 0
        }
    }

    private func audio(_ samples: [Float]) -> AudioBufferSequence {
        let source = AudioBufferStream.make()
        for start in stride(from: 0, to: samples.count, by: 1_600) {
            let piece = samples[start..<min(start + 1_600, samples.count)]
            let buffer = AVAudioPCMBuffer(pcmFormat: ParakeetTranscriber.format, frameCapacity: AVAudioFrameCount(piece.count))!
            buffer.frameLength = AVAudioFrameCount(piece.count)
            piece.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: piece.count) }
            source.continuation.yield(buffer)
        }
        source.continuation.finish()
        return source.stream
    }

    @Test func longDictationIsCutIntoWindowsTheModelCanSee() async throws {
        let fake = FakeCanary()
        let text = try await CanaryTranscriber(decoder: fake).transcribe(
            audio(speechLike(seconds: 27)), locale: Locale(identifier: "en_US"), vocabulary: [], onPartialTranscript: nil
        )
        let segments = await fake.segments
        #expect(segments.count >= 3)
        #expect(segments.allSatisfy { $0 <= 160_000 })
        #expect(segments.reduce(0, +) <= 27 * 16_000)
        #expect(segments.prefix(2).allSatisfy { $0 >= 160_000 - CanaryTranscriber.pauseSearch })
        #expect(text == (1...segments.count).map { "part\($0)" }.joined(separator: " "))
        #expect(await fake.languages == Array(repeating: "en", count: segments.count))
    }

    @Test func silenceIsNeverDecoded() async throws {
        let fake = FakeCanary()
        let text = try await CanaryTranscriber(decoder: fake).transcribe(
            audio([Float](repeating: 0, count: 48_000)), locale: Locale(identifier: "de-DE"), vocabulary: [], onPartialTranscript: nil
        )
        #expect(text.isEmpty)
        #expect(await fake.segments.isEmpty)
    }

    @Test func portugueseIsRefusedSoThePipelineUsesApple() async {
        await #expect(throws: CanaryError.unsupportedLanguage) {
            _ = try await CanaryTranscriber(decoder: FakeCanary()).transcribe(
                audio(speechLike(seconds: 2)), locale: Locale(identifier: "pt-BR"), vocabulary: [], onPartialTranscript: nil
            )
        }
    }

    @Test func piecesJoinIntoWordsWithoutControlTokens() {
        #expect(CanaryModel.text(["▁Hello", ",", "▁wor", "ld", ".", "<|endoftext|>"]) == "Hello, world.")
        #expect(CanaryModel.text(["<|en|>"]).isEmpty)
    }

    @Test func aBundleIsCompleteOnlyWithEveryFileAtItsSize() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CanaryTests-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(CanaryModel.isComplete(at: directory) == false)
        for file in CanaryModel.files {
            let url = directory.appending(path: file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(file.bytes))
            try handle.close()
        }
        #expect(CanaryModel.isComplete(at: directory))
        let last = directory.appending(path: CanaryModel.files.last!.path)
        let handle = try FileHandle(forWritingTo: last)
        try handle.truncate(atOffset: 10)
        try handle.close()
        #expect(CanaryModel.isComplete(at: directory) == false)
        #expect(CanaryModel.downloadBytes == 256_138_163)
    }

    @Test func featuresHaveTheEncoderShapeAndAreNormalizedPerBin() throws {
        let samples: [Float] = (0..<32_000).map { index in
            let time = Float(index) / 16_000
            let tone: Float = 0.2 * sin(2 * Float.pi * 440 * time)
            let hum: Float = 0.01 * sin(Float(index) * 0.37)
            return tone + hum
        }
        let (features, frames) = try CanaryMelSpectrogram().features(samples, window: 1_000)
        #expect(features.shape == [1, 128, 1_000])
        #expect(frames == 200)
        let values = features.dataPointer.assumingMemoryBound(to: Float.self)
        for bin in [10, 64, 120] {
            let row = (0..<frames).map { values[bin * 1_000 + $0] }
            #expect(abs(row.reduce(0, +) / Float(frames)) < 1e-3)
            #expect(values[bin * 1_000 + 500] == 0, "Frames after the audio stay zero")
        }
    }
}
