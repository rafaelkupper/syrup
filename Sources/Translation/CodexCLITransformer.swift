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
        let processBox = RunningProcessBox()

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandResult.self) { group in
                group.addTask {
                    try await runProcess(
                        executableURL: executableURL,
                        arguments: arguments,
                        stdin: stdin,
                        environment: environment,
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

    // Codex may exit before reading all of stdin (a bad flag, a crash). The write then fails with
    // EPIPE instead of raising SIGPIPE, and the exit status below reports what happened.
    let stdinHandle = stdinPipe.fileHandleForWriting
    _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
    do {
        try stdinHandle.write(contentsOf: stdin)
    } catch {
        Logger(subsystem: "org.syrup.SyrupApp", category: "CodexCLI")
            .notice("codex_stdin_write_failed code=\((error as NSError).code, privacy: .public)")
    }
    try? stdinHandle.close()

    // Suspends instead of blocking a cooperative thread for the length of the run.
    await exit.wait()

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
        let trimmedModelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedModelName.isEmpty == false else {
            throw TranslationError.missingConfiguration("codexModel")
        }

        return CodexCLIConfiguration(
            executableURL: executableURL,
            model: trimmedModelName,
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

        let candidates = candidatePaths ?? [
            homeDirectory.appending(path: ".local/bin/codex").path(percentEncoded: false),
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return URL(filePath: path)
        }

        throw TranslationError.codexCLINotFound
    }
}

protocol CodexCLIConfigurationProviding: Sendable {
    func configuration() async throws -> CodexCLIConfiguration
}

struct StaticCodexCLIConfigurationProvider: CodexCLIConfigurationProviding {
    let configuration: CodexCLIConfiguration

    func configuration() async throws -> CodexCLIConfiguration {
        configuration
    }
}

struct CodexCLITransformer: TextTransformer, @unchecked Sendable {
    private let configurationProvider: any CodexCLIConfigurationProviding
    private let commandRunner: any CommandRunning
    private let fileManager: FileManager
    private let timeoutInterval: TimeInterval

    init(
        configuration: CodexCLIConfiguration,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        timeoutInterval: TimeInterval = 60
    ) {
        self.configurationProvider = StaticCodexCLIConfigurationProvider(configuration: configuration)
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.timeoutInterval = timeoutInterval
    }

    init(
        configurationProvider: any CodexCLIConfigurationProviding,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        fileManager: FileManager = .default,
        timeoutInterval: TimeInterval = 60
    ) {
        self.configurationProvider = configurationProvider
        self.commandRunner = commandRunner
        self.fileManager = fileManager
        self.timeoutInterval = timeoutInterval
    }

    func transform(_ text: String, instruction: String) async throws -> String {
        let configuration = try await configurationProvider.configuration()
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
        let prompt = PromptBuilder.codexPrompt(
            instruction: instruction,
            transcript: text
        )
        let arguments = [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--sandbox",
            "read-only",
            "--ignore-user-config",
            "--cd",
            temporaryDirectory.path(percentEncoded: false),
            "--model",
            configuration.model,
            "--output-last-message",
            outputURL.path(percentEncoded: false),
            "-",
        ]

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
