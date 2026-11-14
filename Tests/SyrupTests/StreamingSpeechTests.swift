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

/// Holds an `append` inside the backend until the test releases it.
private final class GatedBackend: StreamingSpeechBackend, Sendable {
    let events = Mutex<[String]>([])
    private let started = AsyncStream<Void>.makeStream()
    private let release = AsyncStream<Void>.makeStream()

    func load(from directory: URL) async throws { events.withLock { $0.append("load") } }
    func unload() async {}
    func begin(localeID: String, onPartialTranscript: (@Sendable (String) -> Void)?) async throws {
        events.withLock { $0.append("begin \(localeID)") }
    }

    func append(_ samples: [Float]) async throws {
        events.withLock { $0.append("append start") }
        started.continuation.yield()
        for await _ in release.stream { break }
        events.withLock { $0.append("append end") }
    }

    func finish() async throws -> String { "" }

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

    /// The cancelled run's chunk is held inside the backend until the next run's `begin` has joined
    /// the queue, so the order below is the one under test in every schedule.
    @Test func aNewRunWaitsForTheChunkACancelledRunIsStillProcessing() async throws {
        let backend = GatedBackend()
        let engine = StreamingSpeechEngine(backend: backend)
        try await engine.load(from: URL(fileURLWithPath: "/nonexistent"))
        let cancelled = Task { try await engine.append([0, 0]) }
        await backend.appendStarted()
        cancelled.cancel()
        let next = Task { try await engine.begin(localeID: "en-US", onPartialTranscript: nil) }
        await eventually { await engine.queuedOperations == 2 }
        backend.releaseAppend()
        try await next.value
        _ = try? await cancelled.value
        #expect(backend.events.withLock { $0 } == ["load", "append start", "append end", "begin en-US"])
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
