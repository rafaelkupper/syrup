import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// One streaming model. Audio arrives as 16 kHz mono samples.
protocol StreamingSpeechBackend: Sendable {
    func load(from directory: URL) async throws
    func unload() async
    func begin(localeID: String, onPartialTranscript: (@Sendable (String) -> Void)?) async throws
    func append(_ samples: [Float]) async throws
    func finish() async throws -> String
}

/// Runs backend calls strictly in order, so a cancelled run still finishing a
/// chunk cannot interleave with the reset that starts the next run.
///
/// Each `begin` opens a numbered session, and `append` and `finish` name the session they
/// belong to. A call from an earlier session is refused when it joins the queue, so a cancelled
/// run that is still draining its converter can never feed audio into the run after it.
actor StreamingSpeechEngine {
    private let backend: any StreamingSpeechBackend
    private var tail: Task<Void, Never>?
    private var isLoaded = false
    /// The most recent session `begin` opened.
    private(set) var currentSession = 0

    init(backend: any StreamingSpeechBackend) {
        self.backend = backend
    }

    func load(from directory: URL) async throws {
        try await inOrder { [backend] in try await backend.load(from: directory) }
        isLoaded = true
    }

    func unload() async {
        isLoaded = false
        _ = try? await inOrder { [backend] in await backend.unload() }
    }

    /// Opens a session and returns its number. The number is taken before waiting for earlier
    /// calls, so from here on every call from an earlier session is refused.
    func begin(localeID: String, onPartialTranscript: (@Sendable (String) -> Void)?) async throws -> Int {
        guard isLoaded else { throw ParakeetError.notLoaded }
        currentSession += 1
        let session = currentSession
        try await inOrder { [backend] in
            try await backend.begin(localeID: localeID, onPartialTranscript: onPartialTranscript)
        }
        return session
    }

    func append(_ samples: [Float], session: Int) async throws {
        guard session == currentSession else { throw CancellationError() }
        try await inOrder { [backend] in try await backend.append(samples) }
    }

    func finish(session: Int) async throws -> String {
        guard session == currentSession else { throw CancellationError() }
        return try await inOrder { [backend] in try await backend.finish() }
    }

    private func inOrder<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
}

struct StreamingTranscriber: Transcriber {
    let engine: StreamingSpeechEngine

    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        let locale = request.locale
        let onPartialTranscript = request.onPartialTranscript
        var converter = AnalyzerAudioConverter(targetFormat: ParakeetTranscriber.format)
        let session = try await engine.begin(localeID: locale.identifier, onPartialTranscript: onPartialTranscript)
        for try await buffer in audio {
            try Task.checkCancellation()
            try await engine.append(Self.samples(in: try converter.convert(buffer)), session: session)
        }
        for buffer in try converter.finish() {
            try Task.checkCancellation()
            try await engine.append(Self.samples(in: buffer), session: session)
        }
        try Task.checkCancellation()
        return try await engine.finish(session: session).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func samples(in buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

enum ModelFiles {
    /// Whether every named file is in `directory`. A compiled Core ML model (`.mlmodelc`) is a folder,
    /// and like FluidAudio this counts it only once its `coremldata.bin` is there.
    static func present(_ names: [String], in directory: URL) -> Bool {
        names.allSatisfy { name in
            var file = directory.appending(path: name)
            if name.hasSuffix(".mlmodelc") { file = file.appending(path: "coremldata.bin") }
            return FileManager.default.fileExists(atPath: file.path(percentEncoded: false))
        }
    }
}

actor NemotronBackend: StreamingSpeechBackend {
    static let chunkMs = 2240
    private static let leadingSilenceSamples = ParakeetTranscriber.sampleRate * 300 / 1_000
    private var manager: StreamingNemotronMultilingualAsrManager?

    static func variantDirectory(in directory: URL) -> URL {
        directory.appending(path: "multilingual/\(chunkMs)ms", directoryHint: .isDirectory)
    }

    /// Every file the manager loads must be there, not just `metadata.json`: a folder missing a
    /// model fails to load, and Retry would load it again instead of downloading.
    static func modelsExist(at directory: URL) -> Bool {
        typealias Names = ModelNames.NemotronMultilingualStreaming
        let variant = variantDirectory(in: directory)
        // The manager accepts any one of these decoder layouts.
        let decoders = [
            ["decoder_joint_argmax.mlmodelc"], ["decoder_joint_noencproj.mlmodelc"], ["decoder_joint.mlmodelc"],
            [Names.decoderFile, Names.jointFile],
        ]
        return ModelFiles.present([Names.metadata, Names.tokenizer, Names.encoderFile], in: variant)
            && decoders.contains { ModelFiles.present($0, in: variant) }
    }

    /// "auto" selects the full multilingual model rather than the six-language Latin one.
    static func download(to root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
            languageCode: "auto", chunkMs: chunkMs, to: root
        ) { progress($0.fractionCompleted) }
    }

    func load(from directory: URL) async throws {
        guard manager == nil else { return }
        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: Self.variantDirectory(in: directory))
        _ = try await manager.process(samples: [Float](repeating: 0, count: 16_000))
        _ = try await manager.finish()
        self.manager = manager
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    func begin(localeID: String, onPartialTranscript: (@Sendable (String) -> Void)?) async throws {
        guard let manager else { throw ParakeetError.notLoaded }
        await manager.reset()
        await manager.setPartialCallback(onPartialTranscript ?? { _ in })
        await manager.setLanguage(localeID.replacingOccurrences(of: "_", with: "-"))
        await manager.tidiesFinalTranscript()
        // Without silence first, this model drops the opening word when speech starts right away.
        _ = try await manager.process(samples: [Float](repeating: 0, count: Self.leadingSilenceSamples))
    }

    func append(_ samples: [Float]) async throws {
        guard let manager else { throw ParakeetError.notLoaded }
        _ = try await manager.process(samples: samples)
    }

    func finish() async throws -> String {
        guard let manager else { throw ParakeetError.notLoaded }
        return try await manager.finish()
    }
}

private extension StreamingNemotronMultilingualAsrManager {
    /// The model usually leaves the last sentence without a period or capital.
    func tidiesFinalTranscript() {
        appendTerminalPunctuation = true
    }
}

actor ParakeetUnifiedBackend: StreamingSpeechBackend {
    private var manager: StreamingUnifiedAsrManager?

    /// The four files `loadModels(from:)` reads, the same set FluidAudio's own download checks.
    static func modelsExist(at directory: URL) -> Bool {
        let config = UnifiedConfig()
        let family = config.family
        return ModelFiles.present([
            family.streamingEncoderFile(precision: .int8, contextSuffix: config.contextSuffix),
            family.decoderFile, family.jointDecisionFile, family.vocab,
        ], in: directory)
    }

    /// FluidAudio's selective fetch takes only the streaming files, not the 11 GB repo, and verifies them by loading.
    static func download(to root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = StreamingUnifiedAsrManager()
        try await manager.loadModels(to: root, progressHandler: { progress($0.fractionCompleted) })
        await manager.cleanup()
    }

    func load(from directory: URL) async throws {
        guard manager == nil else { return }
        let manager = StreamingUnifiedAsrManager()
        try await manager.loadModels(from: directory)
        try await manager.appendAudio(Self.buffer([Float](repeating: 0, count: 16_000)))
        _ = try await manager.finish()
        self.manager = manager
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    func begin(localeID: String, onPartialTranscript: (@Sendable (String) -> Void)?) async throws {
        guard let manager else { throw ParakeetError.notLoaded }
        try await manager.reset()
        await manager.setPartialTranscriptCallback(onPartialTranscript ?? { _ in })
    }

    func append(_ samples: [Float]) async throws {
        guard let manager else { throw ParakeetError.notLoaded }
        try await manager.appendAudio(Self.buffer(samples))
        try await manager.processBufferedAudio()
    }

    func finish() async throws -> String {
        guard let manager else { throw ParakeetError.notLoaded }
        return try await manager.finish()
    }

    private static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: ParakeetTranscriber.format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                buffer.floatChannelData![0].update(from: base, count: samples.count)
            }
        }
        return buffer
    }
}
