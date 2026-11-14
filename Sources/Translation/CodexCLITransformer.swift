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
}

struct ProcessCommandRunner: CommandRunning {
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

                let result = try await group.next() ?? CommandResult(exitCode: 0, stdout: Data(), stderr: Data())
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
    let metrics = CodexCLIProcessMetricsRecorder()
    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    let stdoutCollector = PipeDataCollector(pipe: stdoutPipe) {
        metrics.recordFirstOutput()
    }
    let stderrCollector = PipeDataCollector(pipe: stderrPipe) {
        metrics.recordFirstOutput()
    }

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
    }

    // The prompt is written without blocking a thread, so a CLI that stops reading cannot hold one
    // until the timeout. Exit, timeout, or cancellation closes the pipe.
    let feeder = StdinFeeder(handle: stdinPipe.fileHandleForWriting, data: stdin)
    feeder.start()

    // Suspends instead of blocking a cooperative thread for the length of the run.
    await exit.wait()
    feeder.close()

    let stdout = stdoutCollector.finish()
    let stderr = stderrCollector.finish()

    do {
        try await processBox.throwIfTerminationRequested()
    } catch is CancellationError {
        metrics.recordCompletion(outcome: "canceled")
        throw CancellationError()
    } catch CommandRunnerError.timedOut {
        metrics.recordCompletion(outcome: "timed_out")
        throw CommandRunnerError.timedOut
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
                    Logger(subsystem: "org.syrup.SyrupApp", category: "CodexCLI")
                        .notice("codex_stdin_write_failed code=\(errno, privacy: .public)")
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

private final class PipeDataCollector: @unchecked Sendable {
    private let pipe: Pipe
    private let firstDataHandler: @Sendable () -> Void
    private let lock = NSLock()
    private var bufferedData = Data()
    private var didReceiveData = false

    init(pipe: Pipe, firstDataHandler: @escaping @Sendable () -> Void = {}) {
        self.pipe = pipe
        self.firstDataHandler = firstDataHandler
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard data.isEmpty == false else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(data)
        }
    }

    func finish() -> Data {
        pipe.fileHandleForReading.readabilityHandler = nil
        let remainingData = pipe.fileHandleForReading.availableData
        if remainingData.isEmpty == false {
            append(remainingData)
        }

        return lock.withLock {
            bufferedData
        }
    }

    private func append(_ data: Data) {
        var shouldCallFirstDataHandler = false
        lock.withLock {
            if didReceiveData == false {
                didReceiveData = true
                shouldCallFirstDataHandler = true
            }
            bufferedData.append(data)
        }

        if shouldCallFirstDataHandler {
            firstDataHandler()
        }
    }
}

private final class CodexCLIProcessMetricsRecorder: @unchecked Sendable {
    private let clock = ContinuousClock()
    private let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "CodexCLI")
    private let commandID = UUID()
    private let commandStartedAt: ContinuousClock.Instant
    private let lock = NSLock()
    private var didRecordFirstOutput = false
    private var didRecordCompletion = false

    init() {
        commandStartedAt = clock.now
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
            "codex_cli_stage=\(stage, privacy: .public) command_id=\(self.commandID.uuidString, privacy: .public) outcome=\(outcome, privacy: .public) duration_ms=\(duration.millisecondsDescription, privacy: .public)"
        )
    }
}

private actor RunningProcessBox {
    enum TerminationReason: Sendable {
        case canceled
        case timedOut
    }

    private var process: Process?
    private var terminationReason: TerminationReason?

    func set(_ process: Process) {
        self.process = process
    }

    func requestTermination(reason: TerminationReason, after graceNanoseconds: UInt64) async {
        if terminationReason == nil {
            terminationReason = reason
        }

        await enforceTerminationIfRequested(after: graceNanoseconds)
    }

    func enforceTerminationIfRequested(after graceNanoseconds: UInt64) async {
        guard terminationReason != nil else { return }
        guard let process, process.isRunning else { return }

        process.terminate()

        do {
            try await Task.sleep(nanoseconds: graceNanoseconds)
        } catch {
            return
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    func throwIfTerminationRequested() throws {
        switch terminationReason {
        case .canceled:
            throw CancellationError()
        case .timedOut:
            throw CommandRunnerError.timedOut
        case nil:
            return
        }
    }
}

struct CodexCLIConfiguration: Equatable, Sendable {
    let executableURL: URL
    /// Empty means the account's default model: `--model` is left out.
    let model: String
    let homeDirectory: URL
    let codexHomeDirectory: URL?

    var authFileURL: URL {
        let directory = codexHomeDirectory ?? homeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
        return directory.appending(path: "auth.json")
    }

    var processEnvironment: [String: String] {
        var environment = ["HOME": homeDirectory.path(percentEncoded: false)]
        if let codexHomeDirectory {
            environment["CODEX_HOME"] = codexHomeDirectory.path(percentEncoded: false)
        }
        return environment
    }
}

struct CodexCLIConfigurationResolver: Sendable {
    static func configuration(
        configuredPath: String,
        modelName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        candidatePaths: [String]? = nil
    ) throws -> CodexCLIConfiguration {
        let homeDirectory = URL(
            filePath: environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? NSHomeDirectory(),
            directoryHint: .isDirectory
        )
        let codexHomeDirectory = environment["CODEX_HOME"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
        let executableURL = try executableURL(
            configuredPath: configuredPath,
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            candidatePaths: candidatePaths
        )
        return CodexCLIConfiguration(
            executableURL: executableURL,
            model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            homeDirectory: homeDirectory,
            codexHomeDirectory: codexHomeDirectory
        )
    }

    static func executableURL(
        configuredPath: String,
        homeDirectory: URL,
        fileManager: FileManager = .default,
        candidatePaths: [String]? = nil
    ) throws -> URL {
        let trimmedConfiguredPath = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedConfiguredPath.isEmpty == false {
            guard trimmedConfiguredPath.hasPrefix("/") else {
                throw TranslationError.codexCLINotFound
            }
            let configuredURL = URL(filePath: trimmedConfiguredPath)
            guard fileManager.isExecutableFile(atPath: configuredURL.path(percentEncoded: false)) else {
                throw TranslationError.codexCLINotFound
            }
            return configuredURL
        }

        guard let found = CommandLocator.find(
            "codex", homeDirectory: homeDirectory, fileManager: fileManager, candidatePaths: candidatePaths
        ) else {
            throw TranslationError.codexCLINotFound
        }
        return found
    }
}

struct CodexCLITransformer: TextTransformer, @unchecked Sendable {
    private let configuration: CodexCLIConfiguration
    private let commandRunner: any CommandRunning
    private let fileManager: FileManager
    private let timeoutInterval: TimeInterval

    init(
        configuration: CodexCLIConfiguration,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        timeoutInterval: TimeInterval = 60
    ) {
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.timeoutInterval = timeoutInterval
    }

    /// Codex only rewrites text here, so it gets no way to act: no shell or exec tool, no web search,
    /// apps, plugins, browser, computer use, image tools, sub-agents, memories, or hooks, and approvals
    /// are never requested. The read-only sandbox stays as a second fence. `-c` overrides are used rather
    /// than `--disable`, which exits on a feature an older CLI does not know; an unknown `-c` key only warns.
    static let restrictions: [String] = [
        "--sandbox", "read-only",
        "-c", #"approval_policy="never""#,
        "-c", #"web_search="disabled""#,
        "-c", "features.shell_tool=false",
        "-c", "features.unified_exec=false",
        "-c", "features.apps=false",
        "-c", "features.plugins=false",
        "-c", "features.browser_use=false",
        "-c", "features.computer_use=false",
        "-c", "features.image_generation=false",
        "-c", "features.view_image=false",
        "-c", "features.multi_agent=false",
        "-c", "features.memories=false",
        "-c", "features.hooks=false",
    ]

    /// The full `codex exec` invocation. The prompt goes on stdin (`-`), never in argv. An empty model
    /// leaves `--model` out, so Codex uses the account's default.
    static func arguments(workingDirectory: URL, model: String, outputFile: URL) -> [String] {
        ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config"]
            + restrictions
            + ["--cd", workingDirectory.path(percentEncoded: false)]
            + (model.isEmpty ? [] : ["--model", model])
            + [
                "--output-last-message", outputFile.path(percentEncoded: false),
                "-",
            ]
    }

    func transform(_ text: String, instruction: String) async throws -> String {
        guard fileManager.isReadableFile(atPath: configuration.authFileURL.path(percentEncoded: false)) else {
            throw TranslationError.codexNotSignedIn
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appending(path: "SyrupCodex.\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let outputURL = temporaryDirectory.appending(path: "last-message.txt")
        let prompt = PromptBuilder.fencedPrompt(
            instruction: instruction,
            transcript: text
        )
        let arguments = Self.arguments(
            workingDirectory: temporaryDirectory, model: configuration.model, outputFile: outputURL
        )

        let result: CommandResult
        do {
            result = try await commandRunner.run(
                executableURL: configuration.executableURL,
                arguments: arguments,
                stdin: Data(prompt.utf8),
                environment: configuration.processEnvironment,
                timeout: timeoutInterval
            )
        } catch CommandRunnerError.timedOut {
            throw TranslationError.codexTimedOut
        }

        try mapFailureIfNeeded(result)

        guard let output = try? String(contentsOf: outputURL, encoding: .utf8) else {
            throw TranslationError.codexEmptyOutput
        }

        let normalizedOutput = ModelOutputNormalizer.normalize(
            output,
            keepsWrapperQuotes: ModelOutputNormalizer.requestsQuotes(input: text, instruction: instruction)
        )
        guard normalizedOutput.isEmpty == false else {
            throw TranslationError.codexEmptyOutput
        }

        return normalizedOutput
    }

    private func mapFailureIfNeeded(_ result: CommandResult) throws {
        guard result.exitCode != 0 else { return }

        let stderr = String(decoding: result.stderr, as: UTF8.self)
        let lowercasedStderr = stderr.lowercased()

        if lowercasedStderr.contains("codex login")
            || lowercasedStderr.contains("not signed in")
            || lowercasedStderr.contains("login required")
            || lowercasedStderr.contains("authentication")
            || lowercasedStderr.contains("not authenticated") {
            throw TranslationError.codexNotSignedIn
        }

        if lowercasedStderr.contains("usage limit")
            || lowercasedStderr.contains("rate limit")
            || lowercasedStderr.contains("limit reached") {
            throw TranslationError.codexUsageLimit
        }

        throw TranslationError.codexFailed(Int(result.exitCode))
    }
}

struct CodexCLIStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case ready
        case notFound
        case notSignedIn
        case failed
    }

    let kind: Kind
    let message: String
}

struct CodexCLIStatusChecker: Sendable {
    private let commandRunner: any CommandRunning
    private let timeoutInterval: TimeInterval

    init(
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        timeoutInterval: TimeInterval = 5
    ) {
        self.commandRunner = commandRunner
        self.timeoutInterval = timeoutInterval
    }

    func status(
        configuredPath: String,
        modelName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> CodexCLIStatus {
        do {
            let configuration = try CodexCLIConfigurationResolver.configuration(
                configuredPath: configuredPath,
                modelName: modelName,
                environment: environment
            )
            guard FileManager.default.isReadableFile(
                atPath: configuration.authFileURL.path(percentEncoded: false)
            ) else {
                return CodexCLIStatus(kind: .notSignedIn, message: "not signed in - run `codex login` in Terminal")
            }

            let result = try await commandRunner.run(
                executableURL: configuration.executableURL,
                arguments: ["--version"],
                stdin: Data(),
                environment: configuration.processEnvironment,
                timeout: timeoutInterval
            )
            guard result.exitCode == 0 else {
                return CodexCLIStatus(kind: .failed, message: "status unavailable")
            }

            let version = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayVersion = version.isEmpty ? "Codex CLI" : version
            return CodexCLIStatus(kind: .ready, message: "\(displayVersion), signed in")
        } catch TranslationError.codexCLINotFound {
            return CodexCLIStatus(kind: .notFound, message: "not found")
        } catch {
            return CodexCLIStatus(kind: .failed, message: "status unavailable")
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
}

/// A model the signed-in Codex account offers.
struct CodexModel: Equatable, Sendable, Identifiable {
    let slug: String
    let displayName: String
    var id: String { slug }
}

/// Reads the account's model catalog with `codex debug models`, the list Codex's own picker uses.
/// Hidden models are left out. Any failure returns nil, and Settings falls back to a text field.
struct CodexModelCatalog: Sendable {
    private let commandRunner: any CommandRunning
    private let timeoutInterval: TimeInterval

    init(commandRunner: any CommandRunning = ProcessCommandRunner(), timeoutInterval: TimeInterval = 10) {
        self.commandRunner = commandRunner
        self.timeoutInterval = timeoutInterval
    }

    func models(configuration: CodexCLIConfiguration) async -> [CodexModel]? {
        guard let result = try? await commandRunner.run(
            executableURL: configuration.executableURL,
            arguments: ["debug", "models"],
            stdin: Data(),
            environment: configuration.processEnvironment,
            timeout: timeoutInterval
        ), result.exitCode == 0 else { return nil }
        return Self.parse(result.stdout)
    }

    static func parse(_ data: Data) -> [CodexModel]? {
        struct Catalog: Decodable {
            struct Entry: Decodable {
                let slug: String
                let display_name: String?
                let visibility: String?
                let priority: Int?
            }
            let models: [Entry]
        }
        guard let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return nil }
        let listed = catalog.models
            .filter { ($0.visibility ?? "list") == "list" && $0.slug.isEmpty == false }
            .sorted { ($0.priority ?? .max) < ($1.priority ?? .max) }
            .map { CodexModel(slug: $0.slug, displayName: $0.display_name ?? $0.slug) }
        return listed.isEmpty ? nil : listed
    }
}
