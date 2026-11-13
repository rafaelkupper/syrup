import AVFoundation
import Foundation
import Speech
import Testing
@testable import Syrup

struct AppleTranscriberTests {
    @Test
    func onlyExplicitFastPreferenceEnablesFastResults() {
        let liveOptions = AppleTranscriber.reportingOptions(preferFastResults: true)
        let accurateOptions = AppleTranscriber.reportingOptions(preferFastResults: false)

        #expect(liveOptions.contains(.fastResults))
        #expect(liveOptions.contains(.volatileResults))
        #expect(accurateOptions.contains(.fastResults) == false)
        #expect(accurateOptions.contains(.volatileResults))
    }

    @Test
    func matchingFormatConversionReturnsOriginalBuffer() throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1
        ))
        let buffer = try makeBuffer(format: format, frameLength: 1_600)
        var converter = AnalyzerAudioConverter(targetFormat: format)

        let converted = try converter.convert(buffer)

        #expect(converted === buffer)
    }

    @Test
    func conversionProducesTargetFormat() throws {
        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        let targetFormat = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1
        ))
        let buffer = try makeBuffer(format: sourceFormat, frameLength: 4_800)
        var converter = AnalyzerAudioConverter(targetFormat: targetFormat)

        let converted = try converter.convert(buffer)

        #expect(converted.format.sampleRate == targetFormat.sampleRate)
        #expect(converted.format.channelCount == targetFormat.channelCount)
        #expect(converted.format.commonFormat == targetFormat.commonFormat)
        #expect(converted.format.isInterleaved == targetFormat.isInterleaved)
        #expect(converted.frameLength > 0)
    }

    @Test
    func finishDrainsConverterTailFrames() throws {
        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        let targetFormat = try #require(AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1
        ))
        let buffer = try makeBuffer(format: sourceFormat, frameLength: 4_096)
        var converter = AnalyzerAudioConverter(targetFormat: targetFormat)

        for _ in 0..<10 {
            _ = try converter.convert(buffer)
        }

        let drainedBuffers = try converter.finish()

        #expect(drainedBuffers.contains { $0.frameLength > 0 })
    }

    @Test
    func audioFeedWorkerYieldsConvertedAnalyzerInputs() async throws {
        let sourceFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        // Exercise Float32 capture conversion into an analyzer-compatible format.
        let targetFormat = try #require(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))
        let buffer = try makeBuffer(format: sourceFormat, frameLength: 4_800)
        let audioStream = AudioBufferSequence.makeStream()
        let analyzerInputStream = AsyncStream.makeStream(of: AnalyzerInput.self)
        let worker = AnalyzerAudioFeedWorker(targetFormat: targetFormat)

        audioStream.continuation.yield(buffer)
        audioStream.continuation.finish()

        try await worker.feed(audioStream.stream, into: analyzerInputStream.continuation)
        analyzerInputStream.continuation.finish()

        var inputCount = 0
        for await _ in analyzerInputStream.stream {
            inputCount += 1
        }

        #expect(inputCount > 0)
    }

    @Test
    func analysisContextUsesOnlyFirstHundredExactTerms() throws {
        let vocabulary = (1...101).map { "Term \($0)" }

        let context = try #require(AppleTranscriber.analysisContext(vocabulary: vocabulary))

        #expect(context.contextualStrings[.general] == Array(vocabulary.prefix(100)))
    }

    @Test
    func emptyVocabularyCreatesNoAnalysisContext() {
        let hasContext = AppleTranscriber.analysisContext(vocabulary: []).map { _ in true } ?? false

        #expect(hasContext == false)
    }

    private func makeBuffer(
        format: AVAudioFormat,
        frameLength: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameLength
        ))
        buffer.frameLength = frameLength
        return buffer
    }
}
