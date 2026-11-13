import AVFoundation
import Foundation

// Recognition evaluation worker for Canary 180M Flash. It compiles Syrup's own
// CanaryModel.swift and SpeechSegmenter.swift, and segments audio the way
// CanaryTranscriber does: each full 10 s window is cut at its quietest moment
// in the last 4 s and decoded while later audio is still arriving.

struct EvalRequest: Decodable {
    let wav: String
    let locale: String
    let trimEndMs: Int
    let realtime: Bool
}

struct Recognition: Encodable {
    let hypothesis: String
    let setupMs: Double
    let finalizationMs: Double
    let feedMs: Double
    let audioMs: Double
    let sourceAudioMs: Double
    let trailingSilenceMs: Double
    let loadMs: Double
    let warmupMs: Double
    let boostMs: Double?
}

func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant = .now) -> Double {
    let parts = start.duration(to: end).components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}

func samples(_ path: String, trimEndMs: Int) throws -> (samples: [Float], sourceMs: Double) {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let rate = file.processingFormat.sampleRate
    let count = AVAudioFrameCount(file.length - AVAudioFramePosition(Double(trimEndMs) * rate / 1_000))
    let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
    try file.read(into: source, frameCount: count)
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = AVAudioConverter(from: source.format, to: format)!
    let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(count) * 16_000 / rate) + 1_024)!
    var supplied = false
    _ = converter.convert(to: output, error: nil) { _, status in
        if supplied { status.pointee = .endOfStream; return nil }
        supplied = true
        status.pointee = .haveData
        return source
    }
    return (Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))), Double(file.length) / rate * 1_000)
}

@main
struct CanaryRunner {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: CanaryRunner MODELS_DIRECTORY\n".utf8))
            exit(2)
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = root.appending(path: CanaryModel.folder)
        var model: CanaryModel?
        var loadMs = 0.0
        do {
            if CanaryModel.isComplete(at: directory) == false {
                try await CanaryModel.download(to: root) { _ in }
            }
            let start = ContinuousClock.now
            model = try CanaryModel(directory: directory)
            loadMs = milliseconds(start)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }
        while let line = readLine() {
            do {
                guard let model else { throw CanaryError.incompleteBundle }
                let request = try JSONDecoder().decode(EvalRequest.self, from: Data(line.utf8))
                let language = Locale(identifier: request.locale).language.languageCode?.identifier ?? ""
                let (clip, sourceMs) = try samples(request.wav, trimEndMs: request.trimEndMs)
                var pending: [Float] = []
                var texts: [String] = []
                func decode(_ piece: [Float]) throws {
                    if SpeechSegmenter.containsSpeech(piece) { texts.append(try model.transcribeRecovering(piece, language: language)) }
                }
                let feedStart = ContinuousClock.now
                let chunk = 320
                for offset in stride(from: 0, to: clip.count, by: chunk) {
                    pending.append(contentsOf: clip[offset..<min(offset + chunk, clip.count)])
                    while pending.count > model.windowSamples {
                        let window = Array(pending[..<model.windowSamples])
                        let cut = SpeechSegmenter.pauseCut(in: window, search: 64_000, force: true) ?? model.windowSamples
                        try decode(Array(pending[..<cut]))
                        pending.removeFirst(cut)
                    }
                    if request.realtime {
                        try await Task.sleep(until: feedStart.advanced(by: .seconds(Double(min(offset + chunk, clip.count)) / 16_000)), clock: .continuous)
                    }
                }
                let release = ContinuousClock.now
                try decode(pending)
                let hypothesis = texts.filter { $0.isEmpty == false }.joined(separator: " ")
                let result = Recognition(
                    hypothesis: hypothesis, setupMs: 0, finalizationMs: milliseconds(release),
                    feedMs: milliseconds(feedStart, release), audioMs: Double(clip.count) / 16, sourceAudioMs: sourceMs,
                    trailingSilenceMs: 0, loadMs: loadMs, warmupMs: 0, boostMs: nil
                )
                print(String(decoding: try JSONEncoder().encode(result), as: UTF8.self))
            } catch let error as CanaryError {
                print("{\"error\":\"\(error == .unsupportedLanguage ? "unsupportedLocale" : "modelLoadFailed")\"}")
            } catch {
                print("{\"error\":\"frameworkFailure\",\"code\":\((error as NSError).code)}")
            }
            fflush(stdout)
        }
    }
}
