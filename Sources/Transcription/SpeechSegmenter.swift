import Foundation

/// Energy-based checks on 16 kHz mono samples, shared by the batch speech models.
enum SpeechSegmenter {
    static let sampleRate = 16_000
    static let frameLength = samples(milliseconds: 20)
    private static let pauseFrames = samples(milliseconds: 300) / frameLength
    private static let rumbleFilterPole: Float = 0.97
    private static let speechRise: Float = 4
    private static let quietestSpeechEnergy: Float = 0.0005 * 0.0005
    private static let shortestSpeechFrames = samples(milliseconds: 100) / frameLength

    /// Batch models invent short words such as "Yeah." for audio without speech.
    static func containsSpeech(_ samples: [Float]) -> Bool {
        let energies = frameEnergies(samples)
        guard energies.isEmpty == false else { return false }
        let threshold = speechThreshold(energies)
        return energies.count(where: { $0 >= threshold }) >= shortestSpeechFrames
    }

    /// The middle of the quietest 300 ms in the last `search` samples. Without `force`,
    /// returns nil when even that stretch sounds like speech.
    static func pauseCut(in samples: [Float], search: Int, force: Bool) -> Int? {
        let searchStart = max(0, samples.count - search)
        let energies = frameEnergies(Array(samples[searchStart...]))
        guard energies.count >= pauseFrames else { return force ? samples.count : nil }
        let loudest = (0...(energies.count - pauseFrames)).map { energies[$0..<($0 + pauseFrames)].max() ?? 0 }
        guard let quietest = loudest.indices.min(by: { loudest[$0] < loudest[$1] }),
              force || loudest[quietest] < speechThreshold(energies) else { return nil }
        return searchStart + (quietest + pauseFrames / 2) * frameLength
    }

    static func samples(milliseconds: Int) -> Int {
        sampleRate * milliseconds / 1_000
    }

    private static func speechThreshold(_ energies: [Float]) -> Float {
        let roomFloor = energies.sorted()[energies.count / 10]
        return max(roomFloor * speechRise, quietestSpeechEnergy)
    }

    private static func frameEnergies(_ samples: [Float]) -> [Float] {
        var previousInput: Float = 0
        var previousOutput: Float = 0
        return stride(from: 0, to: samples.count - frameLength + 1, by: frameLength).map { start in
            var sum: Float = 0
            for sample in samples[start..<(start + frameLength)] {
                let output = sample - previousInput + rumbleFilterPole * previousOutput
                previousInput = sample
                previousOutput = output
                sum += output * output
            }
            return sum / Float(frameLength)
        }
    }
}
