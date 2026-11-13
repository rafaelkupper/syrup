import AVFoundation
import FluidAudio
import Foundation

struct EvalRequest: Decodable {
    let wav: String
    let locale: String
    let vocabulary: [String]
    let aliases: [String: [String]]?
    let boostRescue: String?
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

enum EvalFailure: String, Error {
    case modelLoadFailed, audioLength, conversion, unsupportedLocale
}

let sampleRate = 16_000.0

func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant = .now) -> Double {
    let parts = start.duration(to: end).components
    return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
}

func monoSamples(_ source: AVAudioPCMBuffer) throws -> [Float] {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
          let converter = AVAudioConverter(from: source.format, to: format),
          let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(ceil(Double(source.frameLength) * sampleRate / source.format.sampleRate)) + 4096
          ) else { throw EvalFailure.conversion }
    var supplied = false
    var conversionError: NSError?
    let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
        if supplied {
            inputStatus.pointee = .endOfStream
            return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return source
    }
    guard status != .error, conversionError == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] else {
        throw EvalFailure.conversion
    }
    return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
}

struct Booster {
    let context: CustomVocabularyContext
    let spotter: CtcKeywordSpotter
    let rescorer: VocabularyRescorer
    let sizeConfig: ContextBiasingConstants.VocabSizeConfig

    static func make(terms: [String], aliases: [String: [String]], rescue: String?, modelsRoot: URL) async throws -> Booster {
        let directory = modelsRoot.appendingPathComponent(CtcModels.defaultCacheDirectory(for: .ctc110m).lastPathComponent)
        try await CtcModels.download(to: directory, variant: .ctc110m)
        let models = try await CtcModels.load(from: directory, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: directory)
        let context = CustomVocabularyContext(terms: terms.map {
            CustomVocabularyTerm(text: $0, aliases: aliases[$0], ctcTokenIds: tokenizer.encode($0))
        })
        let spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        let config = switch rescue {
        case "off": VocabularyRescorer.Config(spotterRescueEnabled: false)
        case "floors": VocabularyBoostingSession.itnDefaultConfig
        default: VocabularyRescorer.Config.default
        }
        let rescorer = try await VocabularyRescorer.create(spotter: spotter, vocabulary: context, config: config, ctcModelDirectory: directory)
        return Booster(context: context, spotter: spotter, rescorer: rescorer, sizeConfig: ContextBiasingConstants.rescorerConfig(forVocabSize: terms.count))
    }

    func rescore(_ result: ASRResult, audio: [Float]) async throws -> String {
        let spot = try await spotter.spotKeywordsWithLogProbs(audioSamples: audio, customVocabulary: context)
        guard spot.logProbs.isEmpty == false, let timings = result.tokenTimings, timings.isEmpty == false else { return result.text }
        let output = rescorer.ctcTokenRescore(
            transcript: result.text, tokenTimings: timings, logProbs: spot.logProbs, frameDuration: spot.frameDuration,
            cbw: sizeConfig.cbw, marginSeconds: 0.5, minSimilarity: max(sizeConfig.minSimilarity, context.minSimilarity)
        )
        return output.wasModified ? output.text : result.text
    }
}

final class Engine {
    let manager: AsrManager
    let modelsRoot: URL
    let loadMs: Double
    let warmupMs: Double
    private var boosters: [String: Booster] = [:]

    init(manager: AsrManager, modelsRoot: URL, loadMs: Double, warmupMs: Double) {
        self.manager = manager
        self.modelsRoot = modelsRoot
        self.loadMs = loadMs
        self.warmupMs = warmupMs
    }

    static func load(version: AsrModelVersion, modelsRoot: URL) async throws -> Engine {
        let directory = modelsRoot.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent)
        if !AsrModels.modelsExist(at: directory, version: version) {
            try await AsrModels.download(to: directory, version: version)
        }
        let start = ContinuousClock.now
        let manager = AsrManager(config: .default)
        try await manager.loadModels(AsrModels.loadLocal(from: directory, version: version))
        let loaded = ContinuousClock.now
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        _ = try await manager.transcribe([Float](repeating: 0, count: Int(sampleRate)), decoderState: &state)
        return Engine(manager: manager, modelsRoot: modelsRoot, loadMs: milliseconds(start, loaded), warmupMs: milliseconds(loaded))
    }

    func booster(for request: EvalRequest) async throws -> Booster? {
        guard request.vocabulary.isEmpty == false else { return nil }
        let aliases = request.aliases ?? [:]
        let key = String(decoding: try JSONEncoder().encode([request.vocabulary.joined(separator: "\n") + (request.boostRescue ?? ""): aliases]), as: UTF8.self)
        if let booster = boosters[key] { return booster }
        let booster = try await Booster.make(terms: request.vocabulary, aliases: aliases, rescue: request.boostRescue, modelsRoot: modelsRoot)
        boosters[key] = booster
        return booster
    }

    func recognize(_ request: EvalRequest) async throws -> Recognition {
        let booster = try await booster(for: request)
        guard let code = Locale(identifier: request.locale).language.languageCode?.identifier,
              let language = Language(rawValue: code) else { throw EvalFailure.unsupportedLocale }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: request.wav))
        let sourceMs = Double(file.length) / file.processingFormat.sampleRate * 1_000
        let frameCount = file.length - AVAudioFramePosition(Double(request.trimEndMs) * file.processingFormat.sampleRate / 1_000)
        guard frameCount > 0, frameCount <= Int64(UInt32.max),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw EvalFailure.audioLength
        }
        try file.read(into: source, frameCount: AVAudioFrameCount(frameCount))
        let setupStart = ContinuousClock.now
        let clip = try monoSamples(source)
        var lastVoicedFrame = 0
        if let samples = source.floatChannelData {
            for frame in 0..<Int(source.frameLength) {
                for channel in 0..<Int(source.format.channelCount) where abs(samples[channel][frame]) > 0.01 {
                    lastVoicedFrame = frame + 1
                }
            }
        }
        let trailingMs = Double(Int(source.frameLength) - lastVoicedFrame) / source.format.sampleRate * 1_000
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let feedStart = ContinuousClock.now
        let chunk = Int(sampleRate * 0.02)
        var captured: [Float] = []
        captured.reserveCapacity(clip.count)
        for offset in stride(from: 0, to: clip.count, by: chunk) {
            let end = min(offset + chunk, clip.count)
            captured.append(contentsOf: clip[offset..<end])
            if request.realtime {
                try await Task.sleep(until: feedStart.advanced(by: .seconds(Double(end) / sampleRate)), clock: .continuous)
            }
        }
        let release = ContinuousClock.now
        let result = try await manager.transcribe(captured, decoderState: &state, language: language)
        let decoded = ContinuousClock.now
        let hypothesis = try await booster?.rescore(result, audio: captured) ?? result.text
        return Recognition(
            hypothesis: hypothesis, setupMs: milliseconds(setupStart, feedStart), finalizationMs: milliseconds(release),
            feedMs: milliseconds(feedStart, release), audioMs: Double(clip.count) / sampleRate * 1_000,
            sourceAudioMs: sourceMs, trailingSilenceMs: trailingMs, loadMs: loadMs, warmupMs: warmupMs,
            boostMs: booster == nil ? nil : milliseconds(decoded)
        )
    }
}

/// Feeds the clip in 20 ms pieces, as a live recording would, so partial
/// results and the release-to-transcript time match how Syrup runs these models.
final class StreamingEngine {
    private let nemotron: StreamingNemotronMultilingualAsrManager?
    private let unified: StreamingUnifiedAsrManager?
    let loadMs: Double

    private init(nemotron: StreamingNemotronMultilingualAsrManager?, unified: StreamingUnifiedAsrManager?, loadMs: Double) {
        self.nemotron = nemotron
        self.unified = unified
        self.loadMs = loadMs
    }

    static func load(name: String, modelsRoot: URL) async throws -> StreamingEngine? {
        if name == "unified" {
            let manager = StreamingUnifiedAsrManager()
            let start = ContinuousClock.now
            try await manager.loadModels(to: modelsRoot)
            return StreamingEngine(nemotron: nil, unified: manager, loadMs: milliseconds(start))
        }
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count == 3, parts[0] == "nemotron", let chunk = Int(parts[2]) else { return nil }
        let directory = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: parts[1] == "latin" ? "en" : "auto", chunkMs: chunk, to: modelsRoot
        )
        let manager = StreamingNemotronMultilingualAsrManager()
        let start = ContinuousClock.now
        try await manager.loadModels(from: directory)
        return StreamingEngine(nemotron: manager, unified: nil, loadMs: milliseconds(start))
    }

    func recognize(_ request: EvalRequest) async throws -> Recognition {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: request.wav))
        let sourceMs = Double(file.length) / file.processingFormat.sampleRate * 1_000
        let frameCount = file.length - AVAudioFramePosition(Double(request.trimEndMs) * file.processingFormat.sampleRate / 1_000)
        guard frameCount > 0, frameCount <= Int64(UInt32.max),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw EvalFailure.audioLength
        }
        try file.read(into: source, frameCount: AVAudioFrameCount(frameCount))
        let clip = try monoSamples(source)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        if let nemotron {
            try await nemotron.reset()
            await nemotron.setLanguage(request.locale)
            // Matches Syrup: the first chunk loses words unless silence comes before them.
            _ = try await nemotron.process(samples: [Float](repeating: 0, count: Int(sampleRate * 0.3)))
        } else {
            try await unified?.reset()
        }
        let feedStart = ContinuousClock.now
        let chunk = Int(sampleRate * 0.02)
        for offset in stride(from: 0, to: clip.count, by: chunk) {
            let end = min(offset + chunk, clip.count)
            if let nemotron {
                _ = try await nemotron.process(samples: Array(clip[offset..<end]))
            } else if let unified {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - offset))!
                buffer.frameLength = AVAudioFrameCount(end - offset)
                clip[offset..<end].withUnsafeBufferPointer {
                    buffer.floatChannelData![0].update(from: $0.baseAddress!, count: end - offset)
                }
                try await unified.appendAudio(buffer)
                try await unified.processBufferedAudio()
            }
            if request.realtime {
                try await Task.sleep(until: feedStart.advanced(by: .seconds(Double(end) / sampleRate)), clock: .continuous)
            }
        }
        let release = ContinuousClock.now
        let hypothesis = if let nemotron { try await nemotron.finish() } else { try await unified!.finish() }
        return Recognition(
            hypothesis: hypothesis, setupMs: 0, finalizationMs: milliseconds(release),
            feedMs: milliseconds(feedStart, release), audioMs: Double(clip.count) / sampleRate * 1_000,
            sourceAudioMs: sourceMs, trailingSilenceMs: 0, loadMs: loadMs, warmupMs: 0, boostMs: nil
        )
    }
}

func respond(_ line: String) {
    print(line)
    fflush(stdout)
}

@main
struct ParakeetRunner {
    static func main() async {
        AppLogger.mirrorsToConsole = false
        let arguments = CommandLine.arguments
        let versions: [String: AsrModelVersion] = ["v3": .v3, "ultra": .ultra, "redux": .redux]
        guard arguments.count == 3 else {
            FileHandle.standardError.write(Data("usage: ParakeetRunner v3|ultra|redux|unified|nemotron-latin|multi-MS MODELS_DIRECTORY\n".utf8))
            exit(2)
        }
        let modelsRoot = URL(fileURLWithPath: arguments[2])
        var engine: Engine?
        var streaming: StreamingEngine?
        if let version = versions[arguments[1]] {
            engine = try? await Engine.load(version: version, modelsRoot: modelsRoot)
        } else {
            do {
                streaming = try await StreamingEngine.load(name: arguments[1], modelsRoot: modelsRoot)
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
            }
        }
        while let line = readLine() {
            do {
                let request = try JSONDecoder().decode(EvalRequest.self, from: Data(line.utf8))
                let result: Recognition
                if let streaming {
                    result = try await streaming.recognize(request)
                } else if let engine {
                    result = try await engine.recognize(request)
                } else {
                    throw EvalFailure.modelLoadFailed
                }
                let data = try JSONEncoder().encode(result)
                respond(String(decoding: data, as: UTF8.self))
            } catch let error as EvalFailure {
                respond("{\"error\":\"\(error.rawValue)\"}")
            } catch {
                respond("{\"error\":\"frameworkFailure\",\"code\":\((error as NSError).code)}")
            }
        }
    }
}
