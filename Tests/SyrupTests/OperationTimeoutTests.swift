import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// Timeouts that do not wait on operations ignoring cancellation.
@MainActor
struct OperationTimeoutTests {
    @Test func timeoutReturnsEvenWhenOperationIgnoresCancellation() async {
        let gate = UncooperativeOperation()
        await #expect(throws: TranscriptionError.finalizationTimedOut) {
            try await withOperationTimeout(.milliseconds(20), error: TranscriptionError.finalizationTimedOut) {
                await gate.wait()
            }
        }
        await gate.release()
    }

    @Test func frameworkMonitorCannotHoldTimeoutCleanupOpen() async throws {
        let gate = UncooperativeOperation()
        let frameworkTask = Task<Int, any Error> { await gate.wait() }
        let outcome = try await runWhileMonitoring {
            return "completed"
        } monitor: {
            _ = try await awaitCancellableValue(of: frameworkTask)
        }
        #expect(outcome == "completed")
        #expect(frameworkTask.isCancelled)
        await gate.release()
    }
}

private actor UncooperativeOperation {
    private var continuation: CheckedContinuation<Int, Never>?
    private var released = false
    func wait() async -> Int {
        if released { return 1 }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume(returning: 1)
        continuation = nil
    }
}
