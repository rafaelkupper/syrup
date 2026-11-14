import Darwin
import Foundation
import OSLog
import Synchronization

struct CommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

protocol CommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> CommandResult

    /// Runs in `currentDirectory` when given. Fakes that don't care inherit the default below.
    func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data,
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> CommandResult
}

extension CommandRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data,
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        try await run(
            executableURL: executableURL, arguments: arguments, stdin: stdin,
            environment: environment, timeout: timeout
        )
    }
}

enum CommandRunnerError: Error, Equatable, Sendable {
    case timedOut
    /// Stdout passed `ProcessCommandRunner.stdoutLimit`; the process was stopped.
    case outputTooLarge
}

struct ProcessCommandRunner: CommandRunning {
    /// A rewrite is a few kilobytes. Anything past this is a runaway CLI, stopped before it costs memory.
    static let stdoutLimit = 4 * 1_024 * 1_024
    /// Stderr is kept only for the failure messages at its end.
    static let stderrLimit = 64 * 1_024
    /// After the CLI exits, how long to wait for its pipes to close. A helper process that inherited
    /// them can hold them open indefinitely; its output is not waited for.
    static let drainGrace: Duration = .milliseconds(500)

    private let killGraceNanoseconds: UInt64

    init(killGraceNanoseconds: UInt64 = 2_000_000_000) {
        self.killGraceNanoseconds = killGraceNanoseconds
    }

    func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        try await run(
            executableURL: executableURL, arguments: arguments, stdin: stdin,
            environment: environment, currentDirectory: nil, timeout: timeout
        )
    }

    func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data,
        environment: [String: String],
        currentDirectory: URL?,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        let processBox = RunningProcessBox()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult.self) { group in
                group.addTask {
                    try await runProcess(
                        executableURL: executableURL,
                        arguments: arguments,
                        stdin: stdin,
                        environment: environment,
                        currentDirectory: currentDirectory,
                        processBox: processBox,
                        killGraceNanoseconds: killGraceNanoseconds
                    )
                }

                group.addTask {
                    let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
                    try await Task.sleep(nanoseconds: nanoseconds)
                    await processBox.requestTermination(reason: .timedOut, after: killGraceNanoseconds)
                    throw CommandRunnerError.timedOut
                }

                // Both children return or throw, so the group always has a first result.
                guard let result = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                return result
            }
        } onCancel: {
            Task {
                await processBox.requestTermination(reason: .canceled, after: killGraceNanoseconds)
            }
        }
    }
}

private func runProcess(
    executableURL: URL,
    arguments: [String],
    stdin: Data,
    environment: [String: String],
    currentDirectory: URL?,
    processBox: RunningProcessBox,
    killGraceNanoseconds: UInt64
) async throws -> CommandResult {
    let metrics = CLIProcessMetricsRecorder(executableURL: executableURL)
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdoutCollector = PipeDataCollector(
        pipe: stdoutPipe, retention: .head(ProcessCommandRunner.stdoutLimit),
        onOverflow: {
            Task { await processBox.requestTermination(reason: .outputTooLarge, after: killGraceNanoseconds) }
        },
        firstDataHandler: { metrics.recordFirstOutput() }
    )
    let stderrCollector = PipeDataCollector(
        pipe: stderrPipe, retention: .tail(ProcessCommandRunner.stderrLimit),
        firstDataHandler: { metrics.recordFirstOutput() }
    )

    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let exit = ProcessExitSignal()
    process.terminationHandler = { _ in exit.markExited() }

    await processBox.set(process)
    try Task.checkCancellation()
    try await processBox.throwIfTerminationRequested()
    do {
        try metrics.measureSpawn {
            try process.run()
        }
    } catch {
        metrics.recordCompletion(outcome: "failed")
        throw error
    }
    if Task.isCancelled {
        await processBox.requestTermination(reason: .canceled, after: killGraceNanoseconds)
        metrics.recordCompletion(outcome: "canceled")
        throw CancellationError()
    }
    await processBox.enforceTerminationIfRequested(after: killGraceNanoseconds)
    do {
        try await processBox.throwIfTerminationRequested()
    } catch is CancellationError {
        metrics.recordCompletion(outcome: "canceled")
        throw CancellationError()
    } catch CommandRunnerError.timedOut {
        metrics.recordCompletion(outcome: "timed_out")
        throw CommandRunnerError.timedOut
    } catch CommandRunnerError.outputTooLarge {
        metrics.recordCompletion(outcome: "output_too_large")
        throw CommandRunnerError.outputTooLarge
    }

    // The prompt is written without blocking a thread, so a CLI that stops reading cannot hold one
    // until the timeout. Exit, timeout, or cancellation closes the pipe.
    let feeder = StdinFeeder(handle: stdinPipe.fileHandleForWriting, data: stdin)
    feeder.start()

    // Suspends instead of blocking a cooperative thread for the length of the run.
    await exit.wait()
    feeder.close()

    async let stdoutData = stdoutCollector.finish(grace: ProcessCommandRunner.drainGrace)
    async let stderrData = stderrCollector.finish(grace: ProcessCommandRunner.drainGrace)
    let (stdout, stderr) = await (stdoutData, stderrData)

    do {
        try await processBox.throwIfTerminationRequested()
    } catch is CancellationError {
        metrics.recordCompletion(outcome: "canceled")
        throw CancellationError()
    } catch CommandRunnerError.timedOut {
        metrics.recordCompletion(outcome: "timed_out")
        throw CommandRunnerError.timedOut
    } catch CommandRunnerError.outputTooLarge {
        metrics.recordCompletion(outcome: "output_too_large")
        throw CommandRunnerError.outputTooLarge
    }

    metrics.recordCompletion(outcome: process.terminationStatus == 0 ? "success" : "failed")
    return CommandResult(
        exitCode: process.terminationStatus,
        stdout: stdout,
        stderr: stderr
    )
}

/// Writes a child's stdin without blocking a thread. The descriptor is non-blocking, and each chunk
/// waits for the pipe to accept more. Codex may exit before reading all of stdin (a bad flag, a crash):
/// the write then fails with EPIPE instead of raising SIGPIPE, and the exit status reports what happened.
final class StdinFeeder: @unchecked Sendable {
    private let handle: FileHandle
    private let data: Data
    private let lock = NSLock()
    private var offset = 0
    private var isClosed = false

    init(handle: FileHandle, data: Data) {
        self.handle = handle
        self.data = data
    }

    /// Writes what the pipe takes now and returns at once; the rest follows as the reader drains it.
    func start() {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        guard pump() == false else { return }
        handle.writeabilityHandler = { [weak self] _ in
            _ = self?.pump()
        }
    }

    /// Stops writing and closes the pipe. Safe to call more than once.
    func close() {
        lock.withLock { closeLocked() }
    }

    /// Returns true once everything is written or writing has stopped, and the pipe is closed.
    private func pump() -> Bool {
        lock.withLock {
            guard isClosed == false else { return true }
            let descriptor = handle.fileDescriptor
            while offset < data.count {
                let written = data.withUnsafeBytes { buffer -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Darwin.write(descriptor, base + offset, buffer.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else if written < 0, errno == EAGAIN {
                    return false
                } else {
                    Logger(subsystem: "org.syrup.SyrupApp", category: "CLIProvider")
                        .notice("cli_stdin_write_failed code=\(errno, privacy: .public)")
                    break
                }
            }
            closeLocked()
            return true
        }
    }

    private func closeLocked() {
        guard isClosed == false else { return }
        isClosed = true
        handle.writeabilityHandler = nil
        try? handle.close()
    }
}

/// Resumes one waiter when the process exits, whether it exited before or after the wait began.
private final class ProcessExitSignal: Sendable {
    private struct State {
        var exited = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())

    func markExited() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.exited = true
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let exited = state.withLock { state -> Bool in
                if state.exited { return true }
                state.waiter = continuation
                return false
            }
            if exited { continuation.resume() }
        }
    }
}

/// Collects one pipe through its readability handler, without ever blocking a thread on a read.
private final class PipeDataCollector: @unchecked Sendable {
    enum Retention {
        /// Keep the first bytes; past the limit, report overflow once and keep nothing more.
        case head(Int)
        /// Keep the last bytes, where failure messages are.
        case tail(Int)
    }

    private let pipe: Pipe
    private let retention: Retention
    private let onOverflow: @Sendable () -> Void
    private let firstDataHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var bufferedData = Data()
    private var didReceiveData = false
    private var didOverflow = false
    private var reachedEnd = false
    private var endWaiter: CheckedContinuation<Void, Never>?

    init(
        pipe: Pipe,
        retention: Retention,
        onOverflow: @escaping @Sendable () -> Void = {},
        firstDataHandler: @escaping @Sendable () -> Void = {}
    ) {
        self.pipe = pipe
        self.retention = retention
        self.onOverflow = onOverflow
        self.firstDataHandler = firstDataHandler
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty == false else {
                handle.readabilityHandler = nil
                self?.markEnd()
                return
            }
            self?.append(data)
        }
    }

    /// Waits for the pipe to close, up to `grace`, then stops reading and returns what arrived.
    func finish(grace: Duration) async -> Data {
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.markEnd()
        }
        await withCheckedContinuation { continuation in
            let ended = lock.withLock { () -> Bool in
                if reachedEnd { return true }
                endWaiter = continuation
                return false
            }
            if ended { continuation.resume() }
        }
        deadline.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        return lock.withLock { bufferedData }
    }

    private func markEnd() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            reachedEnd = true
            defer { endWaiter = nil }
            return endWaiter
        }
        waiter?.resume()
    }

    private func append(_ data: Data) {
        var isFirst = false
        var overflowed = false
        lock.withLock {
            if didReceiveData == false {
                didReceiveData = true
                isFirst = true
            }
            switch retention {
            case .head(let limit):
                guard didOverflow == false else { return }
                if bufferedData.count + data.count > limit {
                    didOverflow = true
                    overflowed = true
                } else {
                    bufferedData.append(data)
                }
            case .tail(let limit):
                bufferedData.append(data)
                if bufferedData.count > limit {
                    bufferedData = Data(bufferedData.suffix(limit))
                }
            }
        }
        if isFirst { firstDataHandler() }
        if overflowed { onOverflow() }
    }
}

/// Stage timings for one command-line provider run, Codex or Claude Code, named by `tool`.
private final class CLIProcessMetricsRecorder: @unchecked Sendable {
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "CLIProvider")
    private let commandID = UUID()
    private let commandStartedAt: ContinuousClock.Instant
    /// "codex", "claude", or "cli": a fixed word, never the configured path.
    private let tool: String
    private let lock = NSLock()
    private var didRecordFirstOutput = false
    private var didRecordCompletion = false

    init(executableURL: URL) {
        commandStartedAt = clock.now
        let name = executableURL.lastPathComponent.lowercased()
        tool = name.contains("claude") ? "claude" : name.contains("codex") ? "codex" : "cli"
    }

    func measureSpawn(_ operation: () throws -> Void) throws {
        let startedAt = clock.now
        do {
            try operation()
            log(stage: "process_spawn", startedAt: startedAt, outcome: "success")
        } catch {
            log(stage: "process_spawn", startedAt: startedAt, outcome: "failed")
            throw error
        }
    }

    func recordFirstOutput() {
        let shouldRecord = lock.withLock {
            guard didRecordFirstOutput == false else { return false }
            didRecordFirstOutput = true
            return true
        }
        guard shouldRecord else { return }

        log(stage: "first_output", startedAt: commandStartedAt, outcome: "received")
    }

    func recordCompletion(outcome: String) {
        let shouldRecord = lock.withLock {
            guard didRecordCompletion == false else { return false }
            didRecordCompletion = true
            return true
        }
        guard shouldRecord else { return }

        log(stage: "process_completion", startedAt: commandStartedAt, outcome: outcome)
    }

    private func log(stage: String, startedAt: ContinuousClock.Instant, outcome: String) {
        let duration = startedAt.duration(to: clock.now)
        logger.info(
            "cli_stage=\(stage, privacy: .public) tool=\(self.tool, privacy: .public) command_id=\(self.commandID.uuidString, privacy: .public) outcome=\(outcome, privacy: .public) duration_ms=\(duration.millisecondsDescription, privacy: .public)"
        )
    }
}

private actor RunningProcessBox {
    enum TerminationReason: Sendable {
        case canceled
        case timedOut
        case outputTooLarge
    }

    private var process: Process?
    private var terminationReason: TerminationReason?
    private var escalation: Task<Void, Never>?

    func set(_ process: Process) {
        self.process = process
    }

    func requestTermination(reason: TerminationReason, after graceNanoseconds: UInt64) {
        if terminationReason == nil {
            terminationReason = reason
        }

        enforceTerminationIfRequested(after: graceNanoseconds)
    }

    func enforceTerminationIfRequested(after graceNanoseconds: UInt64) {
        guard terminationReason != nil, escalation == nil, let process else { return }

        // `Process` starts the CLI as the leader of its own process group, and the helpers it starts
        // join that group, so signalling the group stops them too. A helper left running would hold
        // the output pipes and, for Claude, the working folder the caller is about to delete. The
        // group is signalled even after the CLI itself exited, while the runner still waits for a
        // helper holding the pipes, for as long as the group has members. Before launch the ID is 0,
        // which would signal Syrup's own group.
        let group = process.processIdentifier
        guard group > 0, process.isRunning || kill(-group, 0) == 0 else { return }
        kill(-group, SIGTERM)

        // The SIGKILL waits in a task of its own that nothing cancels. The caller is often the
        // timeout race, which is cancelled as soon as the CLI exits on SIGTERM; a wait it owned
        // would end there, and a helper that ignored SIGTERM would keep running. The group, and its
        // ID, live on while any helper does. A helper that starts its own group or session is out
        // of reach.
        escalation = Task.detached {
            try? await Task.sleep(nanoseconds: graceNanoseconds)
            if kill(-group, 0) == 0 { kill(-group, SIGKILL) }
        }
    }

    func throwIfTerminationRequested() throws {
        switch terminationReason {
        case .canceled:
            throw CancellationError()
        case .timedOut:
            throw CommandRunnerError.timedOut
        case .outputTooLarge:
            throw CommandRunnerError.outputTooLarge
        case nil:
            return
        }
    }
}

/// Finds a command-line tool where installers put it. A GUI app gets no shell PATH, so the common
/// install locations are checked directly.
enum CommandLocator {
    static func find(
        _ name: String,
        homeDirectory: URL,
        fileManager: FileManager = .default,
        candidatePaths: [String]? = nil
    ) -> URL? {
        let candidates = candidatePaths ?? [
            homeDirectory.appending(path: ".local/bin/\(name)").path(percentEncoded: false),
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }.map { URL(filePath: $0) }
    }

    /// `PATH` for a CLI child. An npm install is a `#!/usr/bin/env node` script, so the interpreter
    /// must be findable: the executable's own folder first (where npm links `node` beside it), then
    /// the Homebrew folders, then the system ones. A GUI app's own `PATH` has none of these.
    static func childPath(for executableURL: URL) -> String {
        let folders = [executableURL.deletingLastPathComponent().path(percentEncoded: false)]
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        return folders
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// The exit status a shell or `env` reports when the launcher's interpreter is missing.
    static let interpreterNotFoundExitCode: Int32 = 127
}
