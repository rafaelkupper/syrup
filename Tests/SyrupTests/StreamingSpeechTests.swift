import AVFoundation
import FluidAudio
import Foundation
import Synchronization
import Testing
@testable import Syrup

private final class FakeBackend: StreamingSpeechBackend, Sendable {
    let events = Mutex<[String]>([])
    let samples = Mutex<Int>(0)

    func load(from directory: URL) async throws { events.withLock { $0.append("load") } }
    func unload() async { events.withLock { $0.append("unload") } }

    func begin(localeID: String, onPartialTranscript: (@Sendable (String) -> Void)?) async throws {
        events.withLock { $0.append("begin \(localeID)") }
        onPartialTranscript?("heard so far")
    }

    func append(_ samples: [Float]) async throws {
        events.withLock { $0.append("append start") }
        self.samples.withLock { $0 += samples.count }
        events.withLock { $0.append("append end") }
    }

    func finish() async throws -> String {
        events.withLock { $0.append("finish") }
        return "  final words \n"
    }
}

/// Holds the first `append` inside the backend until the test releases it; later calls pass.
private final class GatedBackend: StreamingSpeechBackend, Sendable {
    let events = Mutex<[String]>([])
    private let isFirstAppend = Mutex(true)
    private let started = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()

    func load(from directory: URL) async throws { events.withLock { $0.append("load") } }
    func unload() async {}
    func begin(localeID: String, onPartialTranscript: (@Sendable (String) -> Void)?) async throws {
        events.withLock { $0.append("begin \(localeID)") }
    }

    func append(_ samples: [Float]) async throws {
        events.withLock { $0.append("append") }
        let isFirst = isFirstAppend.withLock { isFirst in
            defer { isFirst = false }
            return isFirst
        }
        guard isFirst else { return }
        started.continuation.yield()
        for await _ in release.stream { break }
        events.withLock { $0.append("append end") }
    }

    func finish() async throws -> String {
        events.withLock { $0.append("finish") }
        return ""
    }

    func appendStarted() async {
        for await _ in started.stream { return }
    }

    func releaseAppend() {
        release.continuation.yield()
    }
}

@MainActor
struct StreamingSpeechTests {
    private func audio(frames: AVAudioFrameCount = 1_600, buffers: Int = 3) -> AudioBufferSequence {
        let source = AudioBufferStream.make()
        for _ in 0..<buffers {
            let buffer = AVAudioPCMBuffer(pcmFormat: ParakeetTranscriber.format, frameCapacity: frames)!
            buffer.frameLength = frames
            source.continuation.yield(buffer)
        }
        source.continuation.finish()
        return source.stream
    }

    private func audio48kHz() -> AudioBufferSequence {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096)!
        buffer.frameLength = 4_096
        for frame in 0..<4_096 { buffer.floatChannelData![0][frame] = sin(Float(frame) / 10) }
        let source = AudioBufferStream.make()
        source.continuation.yield(buffer)
        source.continuation.finish()
        return source.stream
    }

    @Test func refusesToRunBeforeLoading() async throws {
        let transcriber = StreamingTranscriber(engine: StreamingSpeechEngine(backend: FakeBackend()))
        await #expect(throws: ParakeetError.notLoaded) {
            _ = try await transcriber.transcribe(audio(), request: TranscriptionRequest(locale: Locale(identifier: "pt_BR"), vocabulary: [], onPartialTranscript: nil))
        }
    }

    @Test func feedsEveryBufferReportsPartialsAndTrimsTheResult() async throws {
        let backend = FakeBackend()
        let engine = StreamingSpeechEngine(backend: backend)
        try await engine.load(from: URL(fileURLWithPath: "/nonexistent"))
        let partials = Mutex<[String]>([])
        let text = try await StreamingTranscriber(engine: engine).transcribe(audio(), request: TranscriptionRequest(locale: Locale(identifier: "pt-BR"), vocabulary: [], onPartialTranscript: { partial in partials.withLock { $0.append(partial) } }))
        #expect(text == "final words")
        #expect(backend.samples.withLock { $0 } == 4_800)
        #expect(partials.withLock { $0 } == ["heard so far"])
        #expect(backend.events.withLock { $0.first { $0.hasPrefix("begin") } } == "begin pt-BR")
    }

    /// The cancelled run's chunk is held inside the backend until the next run's `begin` has
    /// joined the queue, so the order below is the one under test in every schedule.
    @Test func aNewRunWaitsForTheChunkACancelledRunIsStillProcessing() async throws {
        let backend = GatedBackend()
        let engine = StreamingSpeechEngine(backend: backend)
        try await engine.load(from: URL(fileURLWithPath: "/nonexistent"))
        let first = try await engine.begin(localeID: "pt-BR", onPartialTranscript: nil)
        let cancelled = Task { try await engine.append([0, 0], session: first) }
        await backend.appendStarted()
        cancelled.cancel()
        let next = Task { try await engine.begin(localeID: "en-US", onPartialTranscript: nil) }
        await eventually { await engine.currentSession == first + 1 }
        backend.releaseAppend()
        _ = try await next.value
        _ = try? await cancelled.value
        #expect(backend.events.withLock { $0 } == ["load", "begin pt-BR", "append", "append end", "begin en-US"])
    }

    /// 48 kHz input leaves samples in the converter that only `finish()` releases. Once the next
    /// run has begun, the cancelled run must not append them.
    @Test func aCancelledRunCannotFeedItsLastSamplesToTheNextRun() async throws {
        let backend = GatedBackend()
        let engine = StreamingSpeechEngine(backend: backend)
        try await engine.load(from: URL(fileURLWithPath: "/nonexistent"))
        let request = TranscriptionRequest(locale: Locale(identifier: "en-US"), vocabulary: [], onPartialTranscript: nil)
        let cancelled = Task { try await StreamingTranscriber(engine: engine).transcribe(audio48kHz(), request: request) }
        await backend.appendStarted()
        cancelled.cancel()
        let next = Task { try await engine.begin(localeID: "pt-BR", onPartialTranscript: nil) }
        await eventually { await engine.currentSession == 2 }
        backend.releaseAppend()
        _ = try await next.value
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(backend.events.withLock { $0 } == ["load", "begin en-US", "append", "append end", "begin pt-BR"])
    }

    @Test func theSameAudioUncancelledDrainsTheConverterBeforeFinishing() async throws {
        let backend = GatedBackend()
        let engine = StreamingSpeechEngine(backend: backend)
        try await engine.load(from: URL(fileURLWithPath: "/nonexistent"))
        let request = TranscriptionRequest(locale: Locale(identifier: "en-US"), vocabulary: [], onPartialTranscript: nil)
        let run = Task { try await StreamingTranscriber(engine: engine).transcribe(audio48kHz(), request: request) }
        await backend.appendStarted()
        backend.releaseAppend()
        _ = try await run.value
        #expect(backend.events.withLock { $0 } == ["load", "begin en-US", "append", "append end", "append", "finish"])
    }

    @Test func aCallFromAnEarlierSessionIsRefused() async throws {
        let engine = StreamingSpeechEngine(backend: FakeBackend())
        try await engine.load(from: URL(fileURLWithPath: "/nonexistent"))
        let first = try await engine.begin(localeID: "en-US", onPartialTranscript: nil)
        let second = try await engine.begin(localeID: "en-US", onPartialTranscript: nil)
        await #expect(throws: CancellationError.self) { try await engine.append([0], session: first) }
        await #expect(throws: CancellationError.self) { _ = try await engine.finish(session: first) }
        try await engine.append([0], session: second)
        #expect(try await engine.finish(session: second) == "  final words \n")
    }

    /// A folder with the file the old check looked for, but missing a model, is not installed.
    @Test func aStreamingModelCountsAsInstalledOnlyWithEveryFileItLoads() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("StreamingModelFiles"), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        func add(_ names: [String], in directory: URL) throws {
            for name in names {
                var file = directory.appending(path: name)
                if name.hasSuffix(".mlmodelc") { file = file.appending(path: "coremldata.bin") }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: file)
            }
        }

        let nemotron = root.appending(path: "nemotron", directoryHint: .isDirectory)
        let variant = NemotronBackend.variantDirectory(in: nemotron)
        try add(["metadata.json"], in: variant)
        #expect(NemotronBackend.modelsExist(at: nemotron) == false)
        try add(["tokenizer.json", "encoder.mlmodelc", "decoder.mlmodelc"], in: variant)
        #expect(NemotronBackend.modelsExist(at: nemotron) == false, "A decoder without its joint is not a decoder layout")
        try FileManager.default.createDirectory(at: variant.appending(path: "joint.mlmodelc"), withIntermediateDirectories: true)
        #expect(NemotronBackend.modelsExist(at: nemotron) == false, "A model folder without coremldata.bin is unfinished")
        try add(["joint.mlmodelc"], in: variant)
        #expect(NemotronBackend.modelsExist(at: nemotron))

        let unified = root.appending(path: "unified", directoryHint: .isDirectory)
        let config = UnifiedConfig()
        let encoder = config.family.streamingEncoderFile(precision: .int8, contextSuffix: config.contextSuffix)
        try add([encoder], in: unified)
        #expect(ParakeetUnifiedBackend.modelsExist(at: unified) == false)
        try add([config.family.decoderFile, config.family.jointDecisionFile, config.family.vocab], in: unified)
        #expect(ParakeetUnifiedBackend.modelsExist(at: unified))
    }

    /// FluidAudio's logging can carry transcript text. Building the catalog silences it, whichever
    /// engine would have been built first.
    @Test func buildingTheCatalogSilencesFluidAudioLogging() {
        AppLogger.mirrorsToConsole = true
        AppLogger.minimumLevel = .debug
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("Catalog"), directoryHint: .isDirectory)
        _ = SpeechModelCatalog.live(storageDirectory: root)
        #expect(AppLogger.mirrorsToConsole == false)
        #expect(AppLogger.minimumLevel == .fault)
    }

    @Test func modelFoldersMatchFluidAudio() {
        #expect(SpeechEngine.nemotronStreaming.modelFolder == Repo.nemotronMultilingual.folderName)
        #expect(SpeechEngine.parakeetUnifiedEN.modelFolder == Repo.parakeetUnified.folderName)
        #expect(SpeechEngine.canaryFlash.modelFolder == CanaryModel.folder)
        let root = URL(fileURLWithPath: "/x")
        #expect(SpeechEngine.parakeetUltra.modelFolder == ParakeetEngine.modelDirectory(in: root, model: .ultra).lastPathComponent)
        #expect(SpeechEngine.parakeetRedux.modelFolder == ParakeetEngine.modelDirectory(in: root, model: .redux).lastPathComponent)
        #expect(SpeechEngine.retiredParakeetV3Folder == Repo.parakeetV3.folderName)
        for model in [ParakeetEngine.Model.ultra, .redux] {
            #expect(ParakeetEngine.modelDirectory(in: root, model: model).lastPathComponent
                == AsrModels.defaultCacheDirectory(for: model.version).lastPathComponent)
        }
    }

    @Test func eachEngineReportsItsLanguages() {
        #expect(SpeechEngine.parakeetUnifiedEN.supports(localeID: "en-GB"))
        #expect(SpeechEngine.parakeetUnifiedEN.supports(localeID: "pt-BR") == false)
        #expect(SpeechEngine.nemotronStreaming.supports(localeID: "pt-BR"))
        #expect(SpeechEngine.nemotronStreaming.supports(localeID: "ja-JP"))
        #expect(SpeechEngine.nemotronStreaming.supports(localeID: "yue-CN") == false)
        #expect(SpeechEngine.nemotronStreaming.supports(localeID: "el-GR") == false, "Adaptation-ready locales need fine-tuning")
        #expect(SpeechEngine.nemotronStreaming.languageSummary == "28 languages")
        for locale in ["en-US", "de-DE", "es-MX", "fr-CA"] {
            #expect(SpeechEngine.canaryFlash.supports(localeID: locale))
        }
        #expect(SpeechEngine.canaryFlash.supports(localeID: "pt-BR") == false)
    }

    @Test func aRawValueFromANewerBuildFallsBackToApple() throws {
        let decoded = try JSONDecoder().decode(SpeechEngine.self, from: Data("\"future_model\"".utf8))
        #expect(decoded == .apple)
        for engine in SpeechEngine.allCases {
            #expect(try JSONDecoder().decode(SpeechEngine.self, from: JSONEncoder().encode(engine)) == engine)
        }
    }
}
