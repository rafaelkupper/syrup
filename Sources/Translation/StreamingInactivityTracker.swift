import Foundation

typealias StreamingInactivitySleeper = @Sendable (Duration) async throws -> Void

actor StreamingInactivityWatchdog {
    private let timeout: Duration
    private let sleeper: StreamingInactivitySleeper
    private let onTimeout: @Sendable () -> Void
    private var generation: UInt64 = 0
    private var deadlineTask: Task<Void, Never>?

    init(
        timeout: Duration,
        sleeper: @escaping StreamingInactivitySleeper,
        onTimeout: @escaping @Sendable () -> Void
    ) {
        self.timeout = timeout
        self.sleeper = sleeper
        self.onTimeout = onTimeout
    }

    func start() {
        scheduleDeadline()
    }

    func noteDelta() {
        scheduleDeadline()
    }

    func cancel() {
        generation &+= 1
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func scheduleDeadline() {
        generation &+= 1
        let scheduledGeneration = generation
        deadlineTask?.cancel()

        let timeout = timeout
        let sleeper = sleeper
        deadlineTask = Task { [weak self] in
            do {
                try await sleeper(timeout)
                try Task.checkCancellation()
                await self?.deadlineElapsed(for: scheduledGeneration)
            } catch {
                // Cancellation is the normal reset/teardown path. An injected
                // sleeper failure cannot safely be interpreted as a timeout.
            }
        }
    }

    private func deadlineElapsed(for scheduledGeneration: UInt64) {
        guard scheduledGeneration == generation else { return }

        deadlineTask = nil
        onTimeout()
    }
}

enum StreamingTransformError: Error, Equatable, Sendable {
    case requiresAtomicFallback
}
