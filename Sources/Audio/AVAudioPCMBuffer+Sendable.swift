import AVFoundation

// Captured audio buffers are yielded once into the transcription stream and are not mutated after yield.
extension AVAudioPCMBuffer: @unchecked @retroactive Sendable {}
