#!/usr/bin/env bash
set -euo pipefail

voice="${1:-Luciana}"
sample_text="bom dia, tudo bem"
workdir="$(mktemp -d)"
audio_path="$workdir/ptbr.aiff"
swift_path="$workdir/smoke_ptbr_speech.swift"

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

say -v "$voice" -o "$audio_path" "$sample_text"

cat > "$swift_path" <<'SWIFT'
import AVFoundation
import Foundation
import Speech

let audioPath = CommandLine.arguments[1]
let audioURL = URL(fileURLWithPath: audioPath)

Task {
    guard SpeechTranscriber.isAvailable else {
        print("SpeechTranscriber.isAvailable=false")
        exit(1)
    }

    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "pt_BR")) else {
        print("pt_BR supported=false")
        exit(1)
    }

    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: []
    )
    let status = await AssetInventory.status(forModules: [transcriber])
    print("asset_status=\(status)")

    guard status == .installed else {
        print("pt_BR installed=false")
        exit(1)
    }

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        print("compatible_format=false")
        exit(1)
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let analyzerInput = AsyncStream<AnalyzerInput>.makeStream()
    let resultsTask = Task<String, Error> {
        var finalized = ""
        var volatile = ""

        for try await result in transcriber.results {
            let text = String(result.text.characters)
            if result.isFinal {
                finalized += text
                volatile = ""
            } else {
                volatile = text
            }
        }

        return finalized + volatile
    }

    do {
        let file = try AVAudioFile(forReading: audioURL)
        var converter = SmokeAudioConverter(targetFormat: analyzerFormat)

        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try await analyzer.start(inputSequence: analyzerInput.stream)

        while file.framePosition < file.length {
            let remainingFrames = AVAudioFrameCount(min(Int64(4_096), file.length - file.framePosition))
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: remainingFrames
            ) else {
                print("input_buffer=false")
                exit(1)
            }

            try file.read(into: inputBuffer, frameCount: remainingFrames)
            guard inputBuffer.frameLength > 0 else {
                break
            }

            analyzerInput.continuation.yield(AnalyzerInput(buffer: try converter.convert(inputBuffer)))
        }

        for drainedBuffer in try converter.finish() {
            analyzerInput.continuation.yield(AnalyzerInput(buffer: drainedBuffer))
        }

        analyzerInput.continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let transcript = try await resultsTask.value
        let normalized = transcript.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "pt_BR")
        )
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        print("transcript_non_empty=\(trimmed.isEmpty == false)")
        print("contains_bom=\(normalized.contains("bom"))")
        print("contains_dia=\(normalized.contains("dia"))")
        print("contains_tudo=\(normalized.contains("tudo"))")

        guard trimmed.isEmpty == false,
              normalized.contains("bom"),
              normalized.contains("dia"),
              normalized.contains("tudo")
        else {
            exit(1)
        }
    } catch {
        analyzerInput.continuation.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask.cancel()
        print("transcribe_error=\(error)")
        exit(1)
    }

    exit(0)
}

RunLoop.main.run()

struct SmokeAudioConverter {
    private let targetFormat: AVAudioFormat
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var drainFrameCapacity: AVAudioFrameCount = 4_096

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    mutating func convert(_ buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard formatsMatch(buffer.format, targetFormat) == false else {
            return buffer
        }

        if sourceFormat.map({ formatsMatch($0, buffer.format) }) != true {
            guard let newConverter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
                throw SmokeError.audioConversionFailed
            }
            sourceFormat = buffer.format
            converter = newConverter
        }

        guard let converter else {
            throw SmokeError.audioConversionFailed
        }

        let outputFrameCapacity = AVAudioFrameCount(
            max(1, Int(ceil(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)) + 1)
        )
        drainFrameCapacity = max(drainFrameCapacity, outputFrameCapacity)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            throw SmokeError.audioConversionFailed
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
            throw conversionError ?? SmokeError.audioConversionFailed
        @unknown default:
            throw SmokeError.audioConversionFailed
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
                throw SmokeError.audioConversionFailed
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
                throw conversionError ?? SmokeError.audioConversionFailed
            @unknown default:
                throw SmokeError.audioConversionFailed
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

private enum SmokeError: Error {
    case audioConversionFailed
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
SWIFT

swift "$swift_path" "$audio_path"
