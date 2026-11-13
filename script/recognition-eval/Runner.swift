import AVFoundation
import Foundation
import Speech

struct EvalRequest: Decodable {
    let wav: String
    let locale: String
    let vocabulary: [String]
    let trimEndMs: Int
    let realtime: Bool
    let preferFastResults: Bool?
    let prefixAfterSpeechMs: Int?
    let endSilenceMs: Int?
    let wholeBuffer: Bool?
}

struct Recognition: Encodable {
    let hypothesis: String
    let setupMs: Double
    let finalizationMs: Double
    let feedMs: Double
    let audioMs: Double
    let sourceAudioMs: Double
    let trailingSilenceMs: Double
    let finalSegments: Int
    let speechEndMs: Double
    let partialMatchAfterSpeechMs: Double?
    let partialMatchBeforeReleaseMs: Double?
}

enum EvalFailure: String, Error {
    case missingAssets, audioFormat, audioLength, conversion, droppedBuffer
}

func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant = .now) -> Double {
    let parts = start.duration(to: end).components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}

func recognize(_ request: EvalRequest) async throws -> Recognition {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: request.wav))
    let sourceMs = Double(file.length) / file.processingFormat.sampleRate * 1_000
    let sourceFrameCount = file.length - AVAudioFramePosition(Double(request.trimEndMs) * file.processingFormat.sampleRate / 1_000)
    guard sourceFrameCount > 0, sourceFrameCount <= Int64(UInt32.max),
          let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(sourceFrameCount)) else {
        throw EvalFailure.audioLength
    }
    try file.read(into: source, frameCount: AVAudioFrameCount(sourceFrameCount))
    var lastVoicedFrame = 0
    if let samples = source.floatChannelData {
        for frame in 0..<Int(source.frameLength) {
            for channel in 0..<Int(source.format.channelCount) where abs(samples[channel][frame]) > 0.01 {
                lastVoicedFrame = frame + 1
            }
        }
    }
    let rate = source.format.sampleRate
    let speechEndMs = Double(lastVoicedFrame) / rate * 1_000
    let frameCount: Int
    if let prefix = request.prefixAfterSpeechMs {
        frameCount = lastVoicedFrame + Int(Double(prefix) * rate / 1_000)
    } else if let silence = request.endSilenceMs {
        frameCount = max(Int(source.frameLength), lastVoicedFrame + Int(Double(silence) * rate / 1_000))
    } else {
        frameCount = Int(source.frameLength)
    }
    guard frameCount > 0, frameCount <= Int(UInt32.max),
          let audio = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: AVAudioFrameCount(frameCount)) else {
        throw EvalFailure.audioLength
    }
    audio.frameLength = AVAudioFrameCount(frameCount)
    let destination = UnsafeMutableAudioBufferListPointer(audio.mutableAudioBufferList)
    let origin = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
    let bytesPerFrame = Int(source.format.streamDescription.pointee.mBytesPerFrame)
    for channel in 0..<destination.count {
        memset(destination[channel].mData!, 0, frameCount * bytesPerFrame)
        destination[channel].mData!.copyMemory(from: origin[channel].mData!,
            byteCount: min(frameCount, Int(source.frameLength)) * bytesPerFrame)
    }
    let setupStart = ContinuousClock.now
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: request.locale)),
          await SpeechTranscriber.installedLocales.contains(locale) else { throw EvalFailure.missingAssets }
    let transcriber = SpeechTranscriber(
        locale: locale, transcriptionOptions: [],
        reportingOptions: request.preferFastResults == true ? [.volatileResults, .fastResults] : [.volatileResults], attributeOptions: []
    )
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
          let converter = AVAudioConverter(from: source.format, to: format),
          let converted = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(ceil(Double(frameCount) * format.sampleRate / source.format.sampleRate)) + 4096
          ) else { throw EvalFailure.audioFormat }
    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
        if supplied {
            inputStatus.pointee = .endOfStream
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return audio
    }
    guard status != .error, conversionError == nil, converted.frameLength > 0 else { throw EvalFailure.conversion }
    let audioMs = Double(converted.frameLength) / format.sampleRate * 1_000
    let trailingMs = Double(frameCount - lastVoicedFrame) / rate * 1_000
    let input = AsyncStream<AnalyzerInput>.makeStream()
    let results = Task { () throws -> (String, Int, [(String, ContinuousClock.Instant)]) in
        var finalized = ""
        var volatile = ""
        var finalSegments = 0
        var partials: [(String, ContinuousClock.Instant)] = []
        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if result.isFinal {
                finalized += text
                volatile = ""
                finalSegments += 1
            } else {
                volatile = text
            }
            partials.append((finalized + volatile, .now))
        }
        return (finalized + volatile, finalSegments, partials)
    }
    do {
        if !request.vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(request.vocabulary.prefix(100))
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: input.stream)
        let feedStart = ContinuousClock.now
        let setupMs = milliseconds(setupStart, feedStart)
        let totalFrames = Int(converted.frameLength)
        let chunkSize = request.wholeBuffer == true ? totalFrames : Int(format.sampleRate * 0.02)
        for offset in stride(from: 0, to: totalFrames, by: chunkSize) {
            let count = min(chunkSize, totalFrames - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                throw EvalFailure.audioFormat
            }
            buffer.frameLength = AVAudioFrameCount(count)
            let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let origin = UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList)
            let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
            for channel in 0..<destination.count {
                destination[channel].mData!.copyMemory(
                    from: origin[channel].mData!.advanced(by: offset * bytesPerFrame),
                    byteCount: count * bytesPerFrame
                )
            }
            if case .terminated = input.continuation.yield(AnalyzerInput(buffer: buffer)) {
                throw EvalFailure.droppedBuffer
            }
            if request.realtime {
                try await Task.sleep(until: feedStart.advanced(by: .seconds(Double(offset + count) / format.sampleRate)), clock: .continuous)
            }
        }
        let release = ContinuousClock.now
        input.continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let (hypothesis, finalSegments, partials) = try await results.value
        let finalText = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = request.realtime && !finalText.isEmpty ? partials.first { text, time in
            time < release && text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.elementsEqual(finalText.utf8)
        }?.1 : nil
        return Recognition(
            hypothesis: hypothesis, setupMs: setupMs, finalizationMs: milliseconds(release),
            feedMs: milliseconds(feedStart, release), audioMs: audioMs, sourceAudioMs: sourceMs,
            trailingSilenceMs: trailingMs, finalSegments: finalSegments, speechEndMs: speechEndMs,
            partialMatchAfterSpeechMs: match.map { milliseconds(feedStart, $0) - (audioMs - trailingMs) },
            partialMatchBeforeReleaseMs: match.map { milliseconds($0, release) }
        )
    } catch {
        input.continuation.finish()
        results.cancel()
        await analyzer.cancelAndFinishNow()
        throw error
    }
}

@main
struct Runner {
    static func main() async {
        while let line = readLine() {
            do {
                let request = try JSONDecoder().decode(EvalRequest.self, from: Data(line.utf8))
                let result = try await recognize(request)
                let data = try JSONEncoder().encode(result)
                print(String(decoding: data, as: UTF8.self))
                fflush(stdout)
            } catch let error as EvalFailure {
                print("{\"error\":\"\(error.rawValue)\"}")
                fflush(stdout)
            } catch {
                print("{\"error\":\"frameworkFailure\",\"code\":\((error as NSError).code)}")
                fflush(stdout)
            }
        }
    }
}
