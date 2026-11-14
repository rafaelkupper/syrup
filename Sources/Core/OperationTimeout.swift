import Foundation

/// Does not wait indefinitely for a framework operation that ignores cancellation.
/// The owner still cancels the underlying framework session in its error handler.
func withOperationTimeout<Value: Sendable>(
    _ timeout: Duration, error timeoutError: any Error,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream()
    let worker = Task {
        do {
            continuation.yield(try await operation())
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }
    let timer = Task {
        do {
            try await Task.sleep(for: timeout)
            continuation.finish(throwing: timeoutError)
        } catch {}
    }
    defer { worker.cancel(); timer.cancel() }
    var iterator = stream.makeAsyncIterator()
    guard let value = try await iterator.next() else { throw CancellationError() }
    try Task.checkCancellation()
    return value
}

/// An error in either operation cancels the other. A successful monitor does
/// not end the operation early, so final audio still drains before returning.
func runWhileMonitoring<Value: Sendable>(
    operation: @escaping @Sendable () async throws -> Value,
    monitor: @escaping @Sendable () async throws -> Void
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value?.self) { group in
        group.addTask { try await operation() }
        group.addTask { try await monitor(); return nil }
        defer { group.cancelAll() }
        for try await result in group {
            if let result { return result }
        }
        throw CancellationError()
    }
}

/// Await a framework-backed task without letting its cancellation behavior hold
/// the caller open. The task still receives cancellation for its own cleanup.
func awaitCancellableValue<Value: Sendable>(of task: Task<Value, any Error>) async throws -> Value {
    let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream()
    let waiter = Task {
        do {
            continuation.yield(try await task.value)
            continuation.finish()
        } catch { continuation.finish(throwing: error) }
    }
    defer { waiter.cancel() }
    return try await withTaskCancellationHandler {
        var iterator = stream.makeAsyncIterator()
        guard let value = try await iterator.next() else { throw CancellationError() }
        try Task.checkCancellation()
        return value
    } onCancel: {
        task.cancel()
        continuation.finish(throwing: CancellationError())
    }
}
