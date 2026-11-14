import AVFoundation
import Foundation
import OSLog
import Speech

struct AppleTranscriber: Transcriber {
    private let assetManager: TranscriberAssetManager
    private let allowAssetPreparation: Bool

    init(assetManager: TranscriberAssetManager, allowAssetPreparation: Bool = true) {
        self.assetManager = assetManager
        self.allowAssetPreparation = allowAssetPreparation
    }

    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        let locale = request.locale
        let vocabulary = request.vocabulary
        let onPartialTranscript = request.onPartialTranscript
        let preferFastResults = request.preferFastResults
        let metrics = AppleTranscriberMetricsRecorder()
        let supportedLocale = try await metrics.measure(.assetReadiness) {
            try await assetManager.requireInstalled(locale: locale, allowPreparation: allowAssetPreparation)
        }
        let transcriber = SpeechTranscriber(
            locale: supportedLocale,
            transcriptionOptions: [],
            reportingOptions: Self.reportingOptions(
                preferFastResults: preferFastResults
            ),
            attributeOptions: []
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let analyzerFormat = await metrics.measure(.formatLookup) {
            await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        }
        guard let analyzerFormat else {
            throw TranscriptionError.noCompatibleAudioFormat
        }

        let analyzerInput = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(AudioBufferStream.capacity))
        let resultsTask = Self.collectResults(
            from: transcriber,
            onPartialTranscript: onPartialTranscript
        )

        return try await withTaskCancellationHandler {
            do {
                try await metrics.measure(.prepareAndStart) {
                    if let context = Self.analysisContext(vocabulary: vocabulary) {
                        try await analyzer.setContext(context)
                    }
                    try await analyzer.prepareToAnalyze(in: analyzerFormat)
                    try await analyzer.start(inputSequence: analyzerInput.stream)
                }

                try Task.checkCancellation()

                return try await runWhileMonitoring {
                    try await metrics.measure(.audioConversionFeed) {
                        try await AnalyzerAudioFeedWorker(targetFormat: analyzerFormat)
                            .feed(audio, into: analyzerInput.continuation)
                    }

                    analyzerInput.continuation.finish()
                    try Task.checkCancellation()
                    try await metrics.measure(.finalization) {
                        try await withOperationTimeout(.seconds(15), error: TranscriptionError.finalizationTimedOut) {
                            try await analyzer.finalizeAndFinishThroughEndOfInput()
                        }
                    }
                    try Task.checkCancellation()
                    let transcript = try await metrics.measure(.resultCollection) {
                        try await withOperationTimeout(.seconds(15), error: TranscriptionError.finalizationTimedOut) { try await resultsTask.value }
                    }
                    try Task.checkCancellation()
                    return transcript
                } monitor: {
                    _ = try await awaitCancellableValue(of: resultsTask)
                }
            } catch is CancellationError {
                analyzerInput.continuation.finish()
                resultsTask.cancel()
                Task { await analyzer.cancelAndFinishNow() }
                throw CancellationError()
            } catch {
                await assetManager.invalidateInstalledLocale(supportedLocale)
                analyzerInput.continuation.finish()
                resultsTask.cancel()
                Task { await analyzer.cancelAndFinishNow() }
                throw error
            }
        } onCancel: {
            analyzerInput.continuation.finish()
            resultsTask.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Fast recognition is an explicit preference, independent of whether the
    /// cue displays volatile results. Accurate recognition is the default.
    static func reportingOptions(
        preferFastResults: Bool
    ) -> Set<SpeechTranscriber.ReportingOption> {
        preferFastResults ? [.volatileResults, .fastResults] : [.volatileResults]
    }

    static func analysisContext(vocabulary: [String]) -> AnalysisContext? {
        let terms = Array(vocabulary.prefix(GlossaryList.maximumUsedTerms))
        guard terms.isEmpty == false else { return nil }

        let context = AnalysisContext()
        context.contextualStrings[.general] = terms
        return context
    }

    private static func collectResults(
        from transcriber: SpeechTranscriber,
        onPartialTranscript: (@Sendable (String) -> Void)?
    ) -> Task<String, any Error> {
        Task {
            var finalized = ""
            var volatile = ""

            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    onPartialTranscript?(finalized + volatile)
                }
            } catch is CancellationError {
                throw CancellationError()
            }

            return finalized + volatile
        }
    }
}

private enum AppleTranscriberMetricStage: String {
    case assetReadiness
    case formatLookup
    case prepareAndStart
    case audioConversionFeed
    case finalization
    case resultCollection

    var signpostName: StaticString {
        switch self {
        case .assetReadiness:
            "speech_asset_readiness"
        case .formatLookup:
            "speech_format_lookup"
        case .prepareAndStart:
            "speech_prepare_and_start"
        case .audioConversionFeed:
            "speech_audio_conversion_feed"
        case .finalization:
            "speech_finalization"
        case .resultCollection:
            "speech_result_collection"
        }
    }
}

private final class AppleTranscriberMetricsRecorder: @unchecked Sendable {
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "SpeechTranscription")
    private let signposter = OSSignposter(subsystem: "org.syrup.SyrupApp", category: "SpeechTranscription")
    private let transcriptionID = UUID()

    func measure<Value>(
        _ stage: AppleTranscriberMetricStage,
        operation: () async throws -> Value
    ) async throws -> Value {
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval(stage.signpostName, id: signpostID)
        let startedAt = clock.now

        do {
            let value = try await operation()
            finish(stage, state: state, startedAt: startedAt, outcome: "success")
            return value
        } catch is CancellationError {
            finish(stage, state: state, startedAt: startedAt, outcome: "canceled")
            throw CancellationError()
        } catch {
            finish(stage, state: state, startedAt: startedAt, outcome: "failed")
            throw error
        }
    }

    func measure<Value>(
        _ stage: AppleTranscriberMetricStage,
        operation: () async -> Value
    ) async -> Value {
        let signpostID = signposter.makeSignpostID()
        let state = signposter.beginInterval(stage.signpostName, id: signpostID)
        let startedAt = clock.now
        let value = await operation()
        finish(stage, state: state, startedAt: startedAt, outcome: "success")
        return value
    }

    private func finish(
        _ stage: AppleTranscriberMetricStage,
        state: OSSignpostIntervalState,
        startedAt: ContinuousClock.Instant,
        outcome: String
    ) {
        let duration = startedAt.duration(to: clock.now)
        signposter.endInterval(stage.signpostName, state)
        logger.info(
            "speech_stage=\(stage.rawValue, privacy: .public) transcription_id=\(self.transcriptionID.uuidString, privacy: .public) outcome=\(outcome, privacy: .public) duration_ms=\(duration.millisecondsDescription, privacy: .public)"
        )
    }
}

actor AnalyzerAudioFeedWorker {
    private var converter: AnalyzerAudioConverter

    init(targetFormat: AVAudioFormat) {
        converter = AnalyzerAudioConverter(targetFormat: targetFormat)
    }

    func feed(
        _ audio: AudioBufferSequence,
        into continuation: AsyncStream<AnalyzerInput>.Continuation
    ) async throws {
        for try await buffer in audio {
            try Task.checkCancellation()
            let convertedBuffer = try converter.convert(buffer)
            if case .dropped = continuation.yield(AnalyzerInput(buffer: convertedBuffer)) {
                throw AudioRecordingError.audioBufferOverflow
            }
        }

        for convertedBuffer in try converter.finish() {
            try Task.checkCancellation()
            if case .dropped = continuation.yield(AnalyzerInput(buffer: convertedBuffer)) {
                throw AudioRecordingError.audioBufferOverflow
            }
        }
    }
}

struct AnalyzerAudioConverter {
    private let targetFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var drainFrameCapacity: AVAudioFrameCount = 4096

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    mutating func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard formatsMatch(buffer.format, targetFormat) == false else {
            return buffer
        }

        if sourceFormat.map({ formatsMatch($0, buffer.format) }) != true {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                throw TranscriptionError.audioConversionFailed
            }
            sourceFormat = buffer.format
            converter = newConverter
        }

        guard let converter else {
            throw TranscriptionError.audioConversionFailed
        }

        let outputFrameCapacity = AVAudioFrameCount(
            max(1, Int(ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)) + 1)
        )
        drainFrameCapacity = max(drainFrameCapacity, outputFrameCapacity)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw TranscriptionError.audioConversionFailed
        }

        let inputProvider = SingleBufferInputProvider(buffer: buffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            inputProvider.nextBuffer(outStatus: outStatus)
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer
        case .error:
            throw conversionError ?? TranscriptionError.audioConversionFailed
        @unknown default:
            throw TranscriptionError.audioConversionFailed
        }
    }

    mutating func finish() throws -> [AVAudioPCMBuffer] {
        guard let converter else {
            return []
        }

        var drainedBuffers: [AVAudioPCMBuffer] = []
        let inputProvider = EndOfStreamInputProvider()

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: drainFrameCapacity
            ) else {
                throw TranscriptionError.audioConversionFailed
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                inputProvider.nextBuffer(outStatus: outStatus)
            }

            if outputBuffer.frameLength > 0 {
                drainedBuffers.append(outputBuffer)
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                if outputBuffer.frameLength == 0 {
                    return drainedBuffers
                }
            case .endOfStream:
                return drainedBuffers
            case .error:
                throw conversionError ?? TranscriptionError.audioConversionFailed
            @unknown default:
                throw TranscriptionError.audioConversionFailed
            }
        }
    }

    private func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat
            && lhs.isInterleaved == rhs.isInterleaved
    }
}

private final class EndOfStreamInputProvider: @unchecked Sendable {
    private var didSignalEnd = false

    func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didSignalEnd {
            outStatus.pointee = .noDataNow
            return nil
        }

        didSignalEnd = true
        outStatus.pointee = .endOfStream
        return nil
    }
}

private final class SingleBufferInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private var didProvideInput = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func nextBuffer(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if didProvideInput {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideInput = true
        outStatus.pointee = .haveData
        return buffer
    }
}
