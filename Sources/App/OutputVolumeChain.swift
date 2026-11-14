import Foundation
import OSLog

/// Every change to the output volume, run one after another on a single chain, so a lower and its
/// restore never cross, and neither recording nor delivery waits for the chain. A failed change is
/// logged with its error code only and never fails a run. Without a ducker, nothing is queued.
@MainActor
final class OutputVolumeChain {
    private static let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "OutputVolume")
    private let ducker: OutputDucker?
    /// The newest change. It waits for the one before it, so awaiting it awaits them all.
    private(set) var pending: Task<Void, Never>?

    init(ducker: OutputDucker?) {
        self.ducker = ducker
    }

    func lower() {
        enqueue { try await $0.lower() }
    }

    func restore() {
        enqueue { try await $0.restore() }
    }

    func restoreAfterCrash() {
        enqueue { try await $0.restoreAfterCrash() }
    }

    private func enqueue(_ change: @escaping @Sendable (OutputDucker) async throws -> Void) {
        guard let ducker else { return }
        let previous = pending
        pending = Task {
            await previous?.value
            do {
                try await change(ducker)
            } catch {
                let code = (error as? OutputVolumeError).map { String(describing: $0) } ?? "unknown"
                Self.logger.error("output_volume_failed error=\(code, privacy: .public)")
            }
        }
    }
}
