import Foundation
import Observation

@MainActor
@Observable
final class EndpointConnectionTest {
    enum Status: Equatable {
        case idle
        case testing
        case success
        case saved(String)
        case failure(String)
    }

    private(set) var status: Status = .idle
    private var generation = 0

    func invalidate() {
        generation += 1
        status = .idle
    }

    func show(_ status: Status) {
        invalidate()
        self.status = status
    }

    func begin() -> Int {
        generation += 1
        status = .testing
        return generation
    }

    func run(_ generation: Int, operation: () async throws -> Void) async {
        guard generation == self.generation else { return }
        do {
            try await operation()
            guard generation == self.generation else { return }
            status = .success
        } catch {
            guard generation == self.generation else { return }
            status = error is CancellationError ? .idle : .failure(userMessage(for: error))
        }
    }
}
