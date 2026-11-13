import AVFoundation

/// Turns per-buffer RMS values into a smoothed 0...1 loudness level for the
/// recording cue. Attack is faster than release so speech onsets read
/// immediately while the wave decays gently between words.
struct LevelSmoother: Sendable {
    private let floorDecibels: Double
    private let ceilingDecibels: Double
    private let attack: Double
    private let release: Double
    private var current: Double = 0

    init(
        floorDecibels: Double = -50,
        ceilingDecibels: Double = -8,
        attack: Double = 0.55,
        release: Double = 0.2
    ) {
        self.floorDecibels = floorDecibels
        self.ceilingDecibels = ceilingDecibels
        self.attack = attack
        self.release = release
    }

    mutating func process(rms: Double) -> Double {
        let target = Self.normalizedLevel(
            rms: rms,
            floorDecibels: floorDecibels,
            ceilingDecibels: ceilingDecibels
        )
        let coefficient = target > current ? attack : release
        current += (target - current) * coefficient
        return current
    }

    static func normalizedLevel(
        rms: Double,
        floorDecibels: Double,
        ceilingDecibels: Double
    ) -> Double {
        guard rms > 0, ceilingDecibels > floorDecibels else {
            return 0
        }

        let decibels = 20 * log10(rms)
        let normalized = (decibels - floorDecibels) / (ceilingDecibels - floorDecibels)
        return min(max(normalized, 0), 1)
    }
}

extension AVAudioPCMBuffer {
    /// Root-mean-square of all float32 samples, with channels mixed together.
    var rmsLevel: Double? {
        guard format.commonFormat == .pcmFormatFloat32,
              frameLength > 0,
              let channelData = floatChannelData
        else {
            return nil
        }

        let channelCount = Int(format.channelCount)
        let frameCount = Int(frameLength)
        let sampleStride = stride
        var sum = 0.0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                let sample = Double(samples[frame * sampleStride])
                sum += sample * sample
            }
        }

        let sampleCount = frameCount * channelCount
        guard sampleCount > 0 else {
            return nil
        }
        return (sum / Double(sampleCount)).squareRoot()
    }
}

struct AudioLevel: Sendable {
    let dBFS: Double
    let smoothed: Double
}

enum AudioLevelTap {
    static func attach(
        to source: AudioBufferSequence,
        smoother: LevelSmoother = LevelSmoother(),
        onOverflow: @escaping @Sendable () -> Void = {},
        onLevel: @escaping @Sendable (AudioLevel) -> Void
    ) -> AudioBufferSequence {
        let (stream, continuation) = AudioBufferStream.make()
        let task = Task.detached(priority: .userInitiated) {
            var smoother = smoother
            do {
                for try await buffer in source {
                    guard AudioBufferStream.yield(buffer, to: continuation) else {
                        onOverflow()
                        break
                    }
                    if let rms = buffer.rmsLevel {
                        onLevel(AudioLevel(dBFS: 20 * log10(rms), smoothed: smoother.process(rms: rms)))
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
