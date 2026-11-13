import AppKit
import AVFoundation
import Foundation
import Speech

@MainActor
final class SystemMishearingSynthesizer: MishearingSynthesizing {
    func availableVoices() -> [MishearingProbeVoice] {
        AVSpeechSynthesisVoice.speechVoices().map {
            MishearingProbeVoice(
                id: $0.identifier, localeID: $0.language, quality: $0.quality.rawValue,
                isExcluded: $0.voiceTraits.contains(.isNoveltyVoice) || $0.voiceTraits.contains(.isPersonalVoice)
            )
        }
    }

    func synthesize(_ text: String, voice: MishearingProbeVoice) async throws -> [AVAudioPCMBuffer] {
        guard let systemVoice = AVSpeechSynthesisVoice(identifier: voice.id) else {
            throw MishearingProbeFailure.synthesisFailed
        }
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = systemVoice
        let (stream, continuation) = AudioBufferSequence.makeStream()
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else {
                continuation.finish(throwing: MishearingProbeFailure.synthesisFailed)
                return
            }
            guard pcm.frameLength > 0 else { continuation.finish(); return }
            guard let owned = Self.copy(pcm) else {
                continuation.finish(throwing: MishearingProbeFailure.synthesisFailed)
                return
            }
            _ = AudioBufferStream.yield(owned, to: continuation)
        }
        let timer = Task {
            do {
                try await Task.sleep(for: .seconds(30))
                continuation.finish(throwing: MishearingProbeFailure.timedOut)
            } catch {}
        }
        defer {
            timer.cancel()
            synthesizer.stopSpeaking(at: .immediate)
        }
        return try await withTaskCancellationHandler {
            var buffers: [AVAudioPCMBuffer] = []
            var seconds = 0.0
            for try await buffer in stream {
                try Task.checkCancellation()
                seconds += Double(buffer.frameLength) / buffer.format.sampleRate
                guard seconds <= 30 else { throw MishearingProbeFailure.synthesisFailed }
                buffers.append(buffer)
            }
            try Task.checkCancellation()
            guard !buffers.isEmpty else { throw MishearingProbeFailure.synthesisFailed }
            return buffers
        } onCancel: {
            continuation.finish(throwing: CancellationError())
        }
    }

    nonisolated private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (input, output) in zip(source, destination) {
            guard let src = input.mData, let dst = output.mData else { return nil }
            memcpy(dst, src, Int(input.mDataByteSize))
        }
        return copy
    }
}

@MainActor
final class AppleMishearingRecognizer: MishearingRecognizing {
    private let transcriber: AppleTranscriber

    init(assetManager: TranscriberAssetManager) {
        transcriber = AppleTranscriber(assetManager: assetManager, allowAssetPreparation: false)
    }

    func availability(localeID: String) async -> MishearingProbeUnavailableReason? {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeID)) else {
            return .unsupportedLocale
        }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) else { return .speechModelNotInstalled }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return .speechPermissionRequired }
        return nil
    }

    func recognize(_ buffers: [AVAudioPCMBuffer], localeID: String, vocabulary: [String]) async throws -> String {
        let combined = try Self.combinedBuffer(buffers)
        let (audio, continuation) = AudioBufferSequence.makeStream()
        continuation.yield(combined)
        continuation.finish()
        return try await withOperationTimeout(.seconds(60), error: MishearingProbeFailure.timedOut) { [transcriber] in
            try await transcriber.transcribe(
                audio, locale: Locale(identifier: localeID), vocabulary: vocabulary, onPartialTranscript: nil
            )
        }
    }

    static func combinedBuffer(_ buffers: [AVAudioPCMBuffer]) throws -> AVAudioPCMBuffer {
        guard let first = buffers.first, buffers.allSatisfy({ $0.format == first.format }) else {
            throw MishearingProbeFailure.recognitionFailed
        }
        let frames = buffers.reduce(UInt64(0)) { $0 + UInt64($1.frameLength) }
        guard frames > 0, frames <= UInt64(UInt32.max),
              let combined = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw MishearingProbeFailure.recognitionFailed
        }
        combined.frameLength = AVAudioFrameCount(frames)
        let destination = UnsafeMutableAudioBufferListPointer(combined.mutableAudioBufferList)
        var offsets = Array(repeating: 0, count: destination.count)
        for buffer in buffers {
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
            for index in source.indices {
                guard let src = source[index].mData, let dst = destination[index].mData else {
                    throw MishearingProbeFailure.recognitionFailed
                }
                let count = Int(source[index].mDataByteSize)
                memcpy(dst.advanced(by: offsets[index]), src, count)
                offsets[index] += count
            }
        }
        return combined
    }

}

/// Uses the system spelling dictionaries. A language without a dictionary flags nothing.
@MainActor
struct SystemMishearingWordChecker: MishearingWordChecking {
    func isEverydayPhrase(_ phrase: String, localeID: String) -> Bool {
        let checker = NSSpellChecker.shared
        let locale = Locale(identifier: localeID)
        let candidates = [locale.identifier(.icu), locale.language.languageCode?.identifier].compactMap { $0 }
        guard let language = candidates.first(where: { checker.availableLanguages.contains($0) }),
              phrase.contains(where: \.isNumber) == false else { return false }
        let words = phrase.split { !$0.isLetter && $0 != "'" && $0 != "’" }
        guard words.isEmpty == false else { return false }
        return words.allSatisfy {
            checker.checkSpelling(of: String($0), startingAt: 0, language: language, wrap: false,
                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
        }
    }
}
