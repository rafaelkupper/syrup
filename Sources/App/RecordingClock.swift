import Foundation

@MainActor
protocol RecordingClock {
    var now: ContinuousClock.Instant { get }
    func sleep(until deadline: ContinuousClock.Instant) async throws
}

struct ContinuousRecordingClock: RecordingClock {
    var now: ContinuousClock.Instant { .now }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        try await Task.sleep(until: deadline, clock: .continuous)
    }
}
