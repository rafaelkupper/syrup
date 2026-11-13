import Accelerate
import CoreML
import CryptoKit
import Foundation

enum CanaryError: Error, Equatable {
    case incompleteBundle
    case download
    case unsupportedLanguage
    case missingOutput
}

/// NVIDIA Canary 180M Flash through the Core ML export at `aufklarer/Canary-180M-Flash-CoreML`:
/// a 10-second FastConformer encoder, a prefill pass over a nine-token prompt, then one
/// decoder step per token. Self-contained so the recognition evaluation compiles the same code.
final class CanaryModel {
    struct BundleFile: Sendable {
        let path: String
        let bytes: Int
        let sha256: String?
    }

    static let folder = "canary-180m-flash-coreml"
    static let repository = "aufklarer/Canary-180M-Flash-CoreML"
    static let revision = "ca44e0f5d816a2362cf01f7316e4932c86aafef6"
    static let languages: Set<String> = ["en", "de", "es", "fr"]
    static let files: [BundleFile] = [
        BundleFile(path: "config.json", bytes: 4_039, sha256: nil),
        BundleFile(path: "vocab.json", bytes: 85_049, sha256: nil),
        BundleFile(path: "CanaryEncoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "972ff169d06b339fea18b3f7993b75ee4653e617e6d909f8ecc71cbe81a5931e"),
        BundleFile(path: "CanaryEncoder.mlmodelc/coremldata.bin", bytes: 441, sha256: "eb394648361d556a0d241399c094da31d799dca7a8d1b2384a4a50b883336659"),
        BundleFile(path: "CanaryEncoder.mlmodelc/model.mil", bytes: 736_552, sha256: nil),
        BundleFile(path: "CanaryEncoder.mlmodelc/weights/weight.bin", bytes: 108_415_872, sha256: "7b06c888e6aad8e4eb1f6b5a143c3e1482187f521de22fc2f29d09db22ab5f30"),
        BundleFile(path: "CanaryPrefill.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "feed32d599a3bf11d526e7634733883c2033a3fe6b82b1430aaf93cd3f304a3b"),
        BundleFile(path: "CanaryPrefill.mlmodelc/coremldata.bin", bytes: 478, sha256: "15e5e72526a55cbe956af52202cf64e0c5900012044c3d4c090a34236f2a7954"),
        BundleFile(path: "CanaryPrefill.mlmodelc/model.mil", bytes: 118_054, sha256: nil),
        BundleFile(path: "CanaryPrefill.mlmodelc/weights/weight.bin", bytes: 72_804_736, sha256: "1f5a976269018b235476584006b84c86ac76a318d0c34666c3317ac49bdfaff1"),
        BundleFile(path: "CanaryDecoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "a431e30abf4964d771df522ff9a2fb3287bd5477841fc53594aa24fb53891646"),
        BundleFile(path: "CanaryDecoder.mlmodelc/coremldata.bin", bytes: 556, sha256: "e4b81ad3a7cb55b70157d8e6a80949a3a062abea72a9180be6d9201cfba2dc95"),
        BundleFile(path: "CanaryDecoder.mlmodelc/model.mil", bytes: 126_473, sha256: nil),
        BundleFile(path: "CanaryDecoder.mlmodelc/weights/weight.bin", bytes: 73_845_184, sha256: "18c5e693f7981d12b28dbf8bbb15e33f5523d028b01f5baf29f7f5c246268c37"),
    ]

    static var downloadBytes: Int { files.reduce(0) { $0 + $1.bytes } }

    /// Every file is present at its published size. Hashes are checked at download.
    static func isComplete(at directory: URL) -> Bool {
        files.allSatisfy { file in
            let path = directory.appending(path: file.path).path(percentEncoded: false)
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
            return size == file.bytes
        }
    }

    /// Fetches the pinned revision into `root/folder`, keeping files already complete,
    /// and rejects any file whose size or hash differs.
    static func download(to root: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = root.appending(path: folder, directoryHint: .isDirectory)
        let total = Double(downloadBytes)
        var finished = 0
        for file in files {
            let destination = directory.appending(path: file.path)
            if matches(destination, file) {
                finished += file.bytes
                progress(Double(finished) / total)
                continue
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file.path)") else {
                throw CanaryError.download
            }
            let base = finished
            try await FileDownload.fetch(url, to: destination) { written in
                progress(Double(base + Int(written)) / total)
            }
            guard matches(destination, file) else {
                try? FileManager.default.removeItem(at: destination)
                throw CanaryError.download
            }
            finished += file.bytes
        }
    }

    private static func matches(_ url: URL, _ file: BundleFile) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count == file.bytes else { return false }
        guard let expected = file.sha256 else { return true }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == expected
    }

    // MARK: - Model

    private struct Config: Decodable {
        struct CoreMLShapes: Decodable {
            let encoderMelFrames: Int
        }

        let promptIds: [String: [Int]]
        let promptTemplate: [String]
        let specialTokenIds: [String: Int]
        let languageTokenIds: [String: Int]
        let coreml: CoreMLShapes
    }

    let melFrames: Int
    private let config: Config
    private let pieces: [Int: String]
    private let encoder: MLModel
    private let prefill: MLModel
    private let step: MLModel
    private let mel: CanaryMelSpectrogram

    /// Samples the encoder sees at once.
    var windowSamples: Int { melFrames * CanaryMelSpectrogram.hopLength }

    init(directory: URL) throws {
        guard Self.isComplete(at: directory) else { throw CanaryError.incompleteBundle }
        config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: directory.appending(path: "config.json")))
        let vocabulary = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: directory.appending(path: "vocab.json")))
        pieces = Dictionary(uniqueKeysWithValues: vocabulary.compactMap { key, value in Int(key).map { ($0, value) } })
        melFrames = config.coreml.encoderMelFrames
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        encoder = try MLModel(contentsOf: directory.appending(path: "CanaryEncoder.mlmodelc"), configuration: configuration)
        prefill = try MLModel(contentsOf: directory.appending(path: "CanaryPrefill.mlmodelc"), configuration: configuration)
        step = try MLModel(contentsOf: directory.appending(path: "CanaryDecoder.mlmodelc"), configuration: configuration)
        mel = CanaryMelSpectrogram()
    }

    /// The nine-token prompt with the language placed as both source and target, which asks for a transcript.
    func prompt(language: String) throws -> [Int] {
        guard var ids = config.promptIds["en-en"],
              ids.count == config.promptTemplate.count,
              let languageID = config.languageTokenIds[language], Self.languages.contains(language),
              let source = config.promptTemplate.firstIndex(of: "|source_lang|"),
              let target = config.promptTemplate.firstIndex(of: "|target_lang|") else {
            throw CanaryError.unsupportedLanguage
        }
        ids[source] = languageID
        ids[target] = languageID
        return ids
    }

    /// One window of at most `windowSamples` 16 kHz samples. Longer input is cut off, so callers segment first.
    func transcribe(_ samples: [Float], language: String, maximumTokens: Int = 220) throws -> String {
        let prompt = try prompt(language: language)
        guard samples.count >= CanaryMelSpectrogram.hopLength else { return "" }
        let (features, frames) = try mel.features(Array(samples.prefix(windowSamples)), window: melFrames)

        let encoded = try encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_signal": MLFeatureValue(multiArray: features),
            "length": MLFeatureValue(multiArray: try Self.int32([frames])),
        ]))
        guard let embeddings = encoded.featureValue(for: "encoder_embeddings")?.multiArrayValue,
              let mask = encoded.featureValue(for: "encoder_mask")?.multiArrayValue else { throw CanaryError.missingOutput }

        var output = try prefill.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "input_ids": MLFeatureValue(multiArray: try Self.int32(prompt, shape: [1, prompt.count])),
            "encoder_embeddings": MLFeatureValue(multiArray: embeddings),
            "encoder_mask": MLFeatureValue(multiArray: mask),
        ]))
        let endOfText = config.specialTokenIds["eos"] ?? 3
        var tokens: [Int] = []
        for _ in 0..<maximumTokens {
            guard let logits = output.featureValue(for: "logits")?.multiArrayValue,
                  let cache = output.featureValue(for: "decoder_hidden_states")?.multiArrayValue else {
                throw CanaryError.missingOutput
            }
            let token = Self.argmax(logits)
            if token == endOfText { break }
            tokens.append(token)
            // The cache length is the decoder's position, passed in because the graph cannot read it.
            output = try step.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: try Self.int32([token], shape: [1, 1])),
                "encoder_embeddings": MLFeatureValue(multiArray: embeddings),
                "encoder_mask": MLFeatureValue(multiArray: mask),
                "decoder_mems": MLFeatureValue(multiArray: cache),
                "start_pos": MLFeatureValue(multiArray: try Self.int32([cache.shape[2].intValue])),
            ]))
        }
        return Self.text(tokens.compactMap { pieces[$0] })
    }

    /// Canary sometimes ends a window at once, with no words, even though it holds speech.
    /// Splitting at the quietest moment of the middle half and decoding both parts recovers them.
    func transcribeRecovering(_ samples: [Float], language: String) throws -> String {
        let text = try transcribe(samples, language: language)
        let shortest = SpeechSegmenter.samples(milliseconds: 2_000)
        guard text.isEmpty, samples.count >= shortest * 2 else { return text }
        let quarter = samples.count / 4
        let cut = SpeechSegmenter.pauseCut(in: Array(samples[..<(quarter * 3)]), search: quarter * 2, force: true) ?? quarter * 2
        return [Array(samples[..<cut]), Array(samples[cut...])]
            .map { SpeechSegmenter.containsSpeech($0) ? (try? transcribe($0, language: language)) ?? "" : "" }
            .filter { $0.isEmpty == false }
            .joined(separator: " ")
    }

    /// Joins SentencePiece pieces, skipping control tokens; "▁" starts a word.
    static func text(_ pieces: [String]) -> String {
        pieces.filter { $0.hasPrefix("<|") == false }
            .joined()
            .replacingOccurrences(of: "\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func int32(_ values: [Int], shape: [Int]? = nil) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: (shape ?? [values.count]).map(NSNumber.init(value:)), dataType: .int32)
        for (index, value) in values.enumerated() {
            array[index] = NSNumber(value: Int32(value))
        }
        return array
    }

    /// Reads the logits at their own precision; the last axis is the vocabulary.
    private static func argmax(_ logits: MLMultiArray) -> Int {
        let vocabulary = logits.shape.last?.intValue ?? logits.count
        let offset = logits.count - vocabulary
        func scan<T: BinaryFloatingPoint>(_ pointer: UnsafeMutablePointer<T>) -> Int {
            var best = 0
            for index in 1..<vocabulary where pointer[offset + index] > pointer[offset + best] {
                best = index
            }
            return best
        }
        switch logits.dataType {
        case .float16:
            #if arch(arm64)
            return scan(logits.dataPointer.assumingMemoryBound(to: Float16.self))
            #else
            // Float16 arithmetic is unavailable on Intel; the model is offered only on Apple silicon.
            return (0..<vocabulary).max { logits[offset + $0].floatValue < logits[offset + $1].floatValue } ?? 0
            #endif
        case .double:
            return scan(logits.dataPointer.assumingMemoryBound(to: Double.self))
        default:
            return scan(logits.dataPointer.assumingMemoryBound(to: Float.self))
        }
    }
}

/// NeMo's `AudioToMelSpectrogramPreprocessor` as the bundle's config.json specifies it:
/// pre-emphasis 0.97, centred zero-padded STFT (512 FFT, 160 hop, 400 symmetric Hann),
/// power spectrum, 128 Slaney mel bins, log(x + 2^-24), and per-feature normalization
/// with sample variance and a 1e-5 epsilon.
final class CanaryMelSpectrogram {
    static let hopLength = 160
    private static let fftLength = 512
    private static let windowLength = 400
    private static let bins = fftLength / 2 + 1
    private static let melBins = 128
    private static let logGuard: Float = 5.960464477539063e-08
    private let window: [Float]
    private let filterbank: [Float]
    private let fft: FFTSetup

    init() {
        let n = Self.windowLength
        window = (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n - 1)) }
        filterbank = Self.slaneyFilterbank()
        fft = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
    }

    /// `[1, 128, window]` with zeros after the real frames, and the real frame count.
    func features(_ samples: [Float], window frameWindow: Int) throws -> (MLMultiArray, Int) {
        var emphasized = samples
        for index in stride(from: samples.count - 1, to: 0, by: -1) {
            emphasized[index] = samples[index] - 0.97 * samples[index - 1]
        }
        let padding = Self.fftLength / 2
        let padded = [Float](repeating: 0, count: padding) + emphasized + [Float](repeating: 0, count: padding)
        let frames = min(samples.count / Self.hopLength, frameWindow)

        let output = try MLMultiArray(shape: [1, NSNumber(value: Self.melBins), NSNumber(value: frameWindow)], dataType: .float32)
        let values = output.dataPointer.assumingMemoryBound(to: Float.self)
        values.update(repeating: 0, count: Self.melBins * frameWindow)

        let offset = (Self.fftLength - Self.windowLength) / 2
        var frame = [Float](repeating: 0, count: Self.fftLength)
        var real = [Float](repeating: 0, count: Self.fftLength / 2)
        var imaginary = [Float](repeating: 0, count: Self.fftLength / 2)
        var power = [Float](repeating: 0, count: Self.bins)
        var melFrame = [Float](repeating: 0, count: Self.melBins)
        for t in 0..<frames {
            let start = t * Self.hopLength + offset
            for index in 0..<Self.fftLength { frame[index] = 0 }
            for index in 0..<Self.windowLength { frame[offset + index] = padded[start + index] * window[index] }
            real.withUnsafeMutableBufferPointer { realPointer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                    var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                    frame.withUnsafeBytes {
                        vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(Self.fftLength / 2))
                    }
                    vDSP_fft_zrip(fft, &split, 1, 9, FFTDirection(FFT_FORWARD))
                    // vDSP's real FFT is scaled by 2 and packs Nyquist into imagp[0].
                    let dc = split.realp[0] / 2, nyquist = split.imagp[0] / 2
                    power[0] = dc * dc
                    power[Self.fftLength / 2] = nyquist * nyquist
                    for bin in 1..<(Self.fftLength / 2) {
                        let re = split.realp[bin] / 2, im = split.imagp[bin] / 2
                        power[bin] = re * re + im * im
                    }
                }
            }
            vDSP_mmul(power, 1, filterbank, 1, &melFrame, 1, 1, vDSP_Length(Self.melBins), vDSP_Length(Self.bins))
            for bin in 0..<Self.melBins {
                values[bin * frameWindow + t] = log(melFrame[bin] + Self.logGuard)
            }
        }
        if frames > 1 {
            for bin in 0..<Self.melBins {
                let row = values + bin * frameWindow
                var mean: Float = 0
                for t in 0..<frames { mean += row[t] }
                mean /= Float(frames)
                var squares: Float = 0
                for t in 0..<frames { squares += (row[t] - mean) * (row[t] - mean) }
                let deviation = (squares / Float(frames - 1)).squareRoot() + 1e-5
                for t in 0..<frames { row[t] = (row[t] - mean) / deviation }
            }
        }
        return (output, frames)
    }

    /// librosa's Slaney mel filterbank with area normalization, bin-major for vDSP_mmul.
    private static func slaneyFilterbank() -> [Float] {
        func mel(_ hz: Double) -> Double {
            hz < 1_000 ? hz * 3 / 200 : 15 + log(hz / 1_000) / (log(6.4) / 27)
        }
        func hz(_ mel: Double) -> Double {
            mel < 15 ? mel * 200 / 3 : 1_000 * exp((log(6.4) / 27) * (mel - 15))
        }
        let top = mel(8_000)
        let edges = (0...(melBins + 1)).map { hz(top * Double($0) / Double(melBins + 1)) }
        var bank = [Float](repeating: 0, count: bins * melBins)
        for band in 0..<melBins {
            let (left, centre, right) = (edges[band], edges[band + 1], edges[band + 2])
            let norm = 2 / (right - left)
            for bin in 0..<bins {
                let frequency = Double(bin) * 8_000 / Double(bins - 1)
                let weight = max(0, min((frequency - left) / (centre - left), (right - frequency) / (right - centre)))
                bank[bin * melBins + band] = Float(weight * norm)
            }
        }
        return bank
    }
}

/// One file over URLSession, reporting bytes written.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, any Error>?
    private var moveError: (any Error)?
    private let lock = NSLock()

    private init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let delegate = FileDownload(destination: destination, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { continuation in
            delegate.lock.withLock { delegate.continuation = continuation }
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw CanaryError.download }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        if let failure = error ?? lock.withLock({ moveError }) {
            continuation?.resume(throwing: failure)
        } else {
            continuation?.resume()
        }
    }
}
