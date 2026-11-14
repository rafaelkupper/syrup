import Darwin
import Foundation
import Testing
@testable import Syrup

struct CodexCLITransformerTests {
    @Test(arguments: [false, true])
    func atomicResponsePreservesOnlyRequestedQuotes(formatting: Bool) async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let transformer = CodexCLITransformer(
            configuration: try fixture.configuration(auth: true),
            commandRunner: RecordingCommandRunner(behavior: .writeOutput(#"  "good morning"  "#))
        )
        let output = try await transformer.transform(
            "Entre aspas bom dia.",
            instruction: formatting ? PromptBuilder.spokenFormattingInstruction : "Translate to English."
        )
        #expect(output == (formatting ? #""good morning""# : "good morning"))
    }

    @Test
    func resolverUsesConfiguredPathBeforeAutodetectCandidates() throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let configuredCodex = try fixture.executable("configured-codex")
        let candidateCodex = try fixture.executable("candidate-codex")

        let configuration = try CodexCLIConfigurationResolver.configuration(
            configuredPath: configuredCodex.path(percentEncoded: false),
            modelName: " gpt-5.4-mini ",
            environment: ["HOME": fixture.home.path(percentEncoded: false)],
            candidatePaths: [candidateCodex.path(percentEncoded: false)]
        )

        #expect(configuration.executableURL == configuredCodex)
        #expect(configuration.model == "gpt-5.4-mini")
        #expect(configuration.authFileURL == fixture.home.appending(path: ".codex/auth.json"))
        #expect(configuration.processEnvironment == [
            "HOME": fixture.home.path(percentEncoded: false),
            "PATH": CommandLocator.childPath(for: configuredCodex),
        ])
    }

    @Test
    func resolverAutodetectsHomeLocalCodexWithoutUsingPath() throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let homeLocalCodex = fixture.home.appending(path: ".local/bin/codex")
        try fixture.makeExecutable(at: homeLocalCodex)

        let configuration = try CodexCLIConfigurationResolver.configuration(
            configuredPath: "",
            modelName: "gpt-5.4-mini",
            environment: [
                "HOME": fixture.home.path(percentEncoded: false),
                "PATH": "/tmp/should-not-be-used"
            ],
            candidatePaths: nil
        )

        #expect(configuration.executableURL == homeLocalCodex)
    }

    @Test
    func resolverRequiresExecutableAndModel() throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }

        #expect(throws: TranslationError.codexCLINotFound) {
            try CodexCLIConfigurationResolver.configuration(
                configuredPath: fixture.root.appending(path: "missing-codex").path(percentEncoded: false),
                modelName: "gpt-5.4-mini",
                environment: ["HOME": fixture.home.path(percentEncoded: false)]
            )
        }

        #expect(throws: TranslationError.codexCLINotFound) {
            try CodexCLIConfigurationResolver.configuration(
                configuredPath: "codex",
                modelName: "gpt-5.4-mini",
                environment: ["HOME": fixture.home.path(percentEncoded: false)]
            )
        }

        let codex = try fixture.executable("codex")
        let accountDefault = try CodexCLIConfigurationResolver.configuration(
            configuredPath: codex.path(percentEncoded: false),
            modelName: " ",
            environment: ["HOME": fixture.home.path(percentEncoded: false)]
        )
        #expect(accountDefault.model.isEmpty)
    }

    @Test
    func translateInvokesCodexWithExpectedArgumentsAndPromptOnStdin() async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let configuration = try fixture.configuration(auth: true)
        let runner = RecordingCommandRunner(behavior: .writeOutput(#"  "Good morning"  "#))
        let transformer = CodexCLITransformer(
            configuration: configuration,
            commandRunner: runner,
            timeoutInterval: 60
        )

        let result = try await transformer.transform(
            "bom dia",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "Use a concise tone.")
        )

        #expect(result == "Good morning")

        let calls = await runner.calls
        let call = try #require(calls.first)
        #expect(call.executableURL == configuration.executableURL)
        let directory = try #require(call.arguments.firstIndex(of: "--cd").map { call.arguments[$0 + 1] })
        #expect(directory.contains("SyrupCodex."))
        // The result comes back on stdout; Codex is never asked to write it to a file.
        #expect(call.arguments.contains("--output-last-message") == false)
        // Pinned in full: Codex gets no tools, no approvals, no web, and the prompt only on stdin.
        #expect(call.arguments == [
            "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config",
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
            "--cd", directory,
            "--model", "gpt-5.4-mini",
            "-",
        ])
        #expect(call.environment == [
            "HOME": fixture.home.path(percentEncoded: false),
            "PATH": CommandLocator.childPath(for: configuration.executableURL),
        ])
        #expect(call.timeout == 60)

        let stdin = String(decoding: call.stdin, as: UTF8.self)
        #expect(stdin.contains("Do not use tools or commands."))
        #expect(stdin.contains("bom dia\nEND INPUT "))
    }

    @Test
    func translateUsesCodexHomeForAuthAndEnvironmentWhenSet() async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let codexHome = fixture.root.appending(path: "custom-codex-home", directoryHint: .isDirectory)
        let configuration = try fixture.configuration(auth: true, codexHome: codexHome)
        let runner = RecordingCommandRunner(behavior: .writeOutput("Good morning"))
        let transformer = CodexCLITransformer(configuration: configuration, commandRunner: runner)

        _ = try await transformer.transform(
            "bom dia",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
        )

        let calls = await runner.calls
        let call = try #require(calls.first)
        #expect(call.environment == [
            "HOME": fixture.home.path(percentEncoded: false),
            "CODEX_HOME": codexHome.path(percentEncoded: false),
            "PATH": CommandLocator.childPath(for: configuration.executableURL),
        ])
    }

    @Test
    func missingAuthFileFailsBeforeSpawningCommand() async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let configuration = try fixture.configuration(auth: false)
        let runner = RecordingCommandRunner(behavior: .writeOutput("unused"))
        let transformer = CodexCLITransformer(configuration: configuration, commandRunner: runner)

        await #expect(throws: TranslationError.codexNotSignedIn) {
            _ = try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }

        let calls = await runner.calls
        #expect(calls.isEmpty)
    }

    @Test(arguments: [
        ("please run codex login", TranslationError.codexNotSignedIn),
        ("usage limit reached", TranslationError.codexUsageLimit),
    ])
    func stderrMapsKnownCodexFailures(stderr: String, expectedError: TranslationError) async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let configuration = try fixture.configuration(auth: true)
        let runner = RecordingCommandRunner(behavior: .missingOutput(exitCode: 1, stderr: stderr))
        let transformer = CodexCLITransformer(configuration: configuration, commandRunner: runner)

        await #expect(throws: expectedError) {
            _ = try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test
    func successfulCommandIgnoresBenignAuthWarningsOnStderr() async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let configuration = try fixture.configuration(auth: true)
        let runner = RecordingCommandRunner(
            behavior: .writeOutputWithStderr("Good morning", "auth cache refreshed")
        )
        let transformer = CodexCLITransformer(configuration: configuration, commandRunner: runner)

        let result = try await transformer.transform(
            "bom dia",
            instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
        )

        #expect(result == "Good morning")
    }

    @Test
    func nonZeroExitMapsWithoutLeakingStderr() async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let configuration = try fixture.configuration(auth: true)
        let runner = RecordingCommandRunner(behavior: .missingOutput(exitCode: 42, stderr: "raw details"))
        let transformer = CodexCLITransformer(configuration: configuration, commandRunner: runner)

        await #expect(throws: TranslationError.codexFailed(42)) {
            _ = try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test(arguments: [
        RecordingCommandRunner.Behavior.writeOutput("   "),
        RecordingCommandRunner.Behavior.missingOutput(exitCode: 0, stderr: ""),
    ])
    func emptyOrMissingOutputMapsToEmptyOutput(behavior: RecordingCommandRunner.Behavior) async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let configuration = try fixture.configuration(auth: true)
        let runner = RecordingCommandRunner(behavior: behavior)
        let transformer = CodexCLITransformer(configuration: configuration, commandRunner: runner)

        await #expect(throws: TranslationError.codexEmptyOutput) {
            _ = try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test
    func runnerTimeoutMapsToCodexTimedOut() async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let configuration = try fixture.configuration(auth: true)
        let runner = RecordingCommandRunner(behavior: .failure(CommandRunnerError.timedOut))
        let transformer = CodexCLITransformer(configuration: configuration, commandRunner: runner)

        await #expect(throws: TranslationError.codexTimedOut) {
            _ = try await transformer.transform(
                "bom dia",
                instruction: PromptBuilder.systemPrompt(targetLanguage: "English", toneInstruction: "")
            )
        }
    }

    @Test
    func processRunnerTimeoutTerminatesStubbornProcess() async {
        let runner = ProcessCommandRunner(killGraceNanoseconds: 50_000_000)

        await #expect(throws: CommandRunnerError.timedOut) {
            _ = try await runner.run(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; exec sleep 5"],
                stdin: Data(),
                environment: [:],
                timeout: 0.05
            )
        }
    }

    /// A CLI that never reads a prompt bigger than the pipe buffer must not hold a thread. With a
    /// blocking write, more such runs than cores starved the pool, and even the timeouts could not fire:
    /// 28 runs with a 1 s timeout took 10 s on the measuring Mac. Each run must end at its timeout.
    @Test
    func runsThatNeverReadTheirPromptStillEndAtTheTimeout() async throws {
        let runner = ProcessCommandRunner(killGraceNanoseconds: 50_000_000)
        let prompt = Data(repeating: 0x61, count: 1 << 20)
        let clock = ContinuousClock()
        let started = clock.now
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<(ProcessInfo.processInfo.activeProcessorCount + 2) {
                group.addTask {
                    do {
                        _ = try await runner.run(executableURL: URL(filePath: "/bin/sleep"), arguments: ["5"],
                                                 stdin: prompt, environment: [:], timeout: 0.3)
                        return false
                    } catch CommandRunnerError.timedOut {
                        return true
                    } catch {
                        return false
                    }
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }
        #expect(outcomes.allSatisfy { $0 })
        #expect(started.duration(to: clock.now) < .seconds(3))
    }

    @Test
    func stdinFeederNeverWaitsOnAReaderThatDoesNotRead() throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        let feeder = StdinFeeder(handle: pipe.fileHandleForWriting, data: Data(repeating: 0x61, count: 1 << 20))
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            feeder.start()
            feeder.close()
        }
        #expect(elapsed < .milliseconds(100))
    }

    @Test
    func stdinFeederDeliversEverythingThenEndOfFile() async throws {
        let pipe = Pipe()
        let payload = Data((0..<(300 * 1_024)).map { UInt8($0 % 251) })
        let feeder = StdinFeeder(handle: pipe.fileHandleForWriting, data: payload)
        feeder.start()
        let reader = pipe.fileHandleForReading
        let received = try await Task.detached { try reader.readToEnd() ?? Data() }.value
        #expect(received == payload)
        feeder.close()
    }

    @Test
    func processRunnerCancellationTerminatesRunningProcess() async throws {
        let runner = ProcessCommandRunner(killGraceNanoseconds: 50_000_000)
        let markerURL = FileManager.default.temporaryDirectory
            .appending(path: testDomainName("SyrupCancel"))
        defer {
            try? FileManager.default.removeItem(at: markerURL)
        }

        let task = Task {
            try await runner.run(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "echo $$ > '\(markerURL.path(percentEncoded: false))'; trap '' TERM; while true; do sleep 1; done",
                ],
                stdin: Data(),
                environment: [:],
                timeout: 10
            )
        }

        for _ in 0..<200 where FileManager.default.fileExists(atPath: markerURL.path(percentEncoded: false)) == false {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let pidText = try String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = pid_t(try #require(Int32(pidText)))

        task.cancel()

        var caughtCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            caughtCancellation = true
        }
        #expect(caughtCancellation)

        for _ in 0..<200 where Darwin.kill(pid, 0) == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(Darwin.kill(pid, 0) != 0)
    }

    @Test
    func processRunnerDrainsChattyOutputWhileProcessRuns() async throws {
        let runner = ProcessCommandRunner()
        let outputSize = 512 * 1_024

        let result = try await runner.run(
            executableURL: URL(filePath: "/usr/bin/python3"),
            arguments: [
                "-c",
                "import sys; sys.stdout.write('o' * \(outputSize)); sys.stderr.write('e' * \(outputSize))",
            ],
            stdin: Data(),
            environment: [:],
            timeout: 5
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.count == outputSize)
        // Stderr is drained in full while the process runs; only its end is kept.
        #expect(result.stderr.count == ProcessCommandRunner.stderrLimit)
    }

    @Test
    func statusCheckerReportsVersionWhenSignedIn() async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let codex = try fixture.executable("codex")
        try fixture.createAuthFile()
        let runner = RecordingCommandRunner(behavior: .stdout("codex-cli 0.135.0\n"))
        let checker = CodexCLIStatusChecker(commandRunner: runner)

        let status = await checker.status(
            configuredPath: codex.path(percentEncoded: false),
            modelName: "gpt-5.4-mini",
            environment: ["HOME": fixture.home.path(percentEncoded: false)]
        )

        #expect(status == CodexCLIStatus(kind: .ready, message: "codex-cli 0.135.0, signed in"))
    }

    @Test
    func statusCheckerReportsNotSignedInWithoutAuthFile() async throws {
        let fixture = try CodexFixture()
        defer { fixture.cleanup() }
        let codex = try fixture.executable("codex")
        let checker = CodexCLIStatusChecker(commandRunner: RecordingCommandRunner(behavior: .stdout("")))

        let status = await checker.status(
            configuredPath: codex.path(percentEncoded: false),
            modelName: "gpt-5.4-mini",
            environment: ["HOME": fixture.home.path(percentEncoded: false)]
        )

        #expect(status == CodexCLIStatus(
            kind: .notSignedIn,
            message: "not signed in - run `codex login` in Terminal"
        ))
    }
}

private struct CodexFixture {
    let root: URL
    let home: URL
    let executableURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: testDomainName("SyrupCodexTests"), directoryHint: .isDirectory)
        home = root.appending(path: "home", directoryHint: .isDirectory)
        executableURL = root.appending(path: "codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try makeExecutable(at: executableURL)
    }

    func configuration(auth: Bool, codexHome: URL? = nil) throws -> CodexCLIConfiguration {
        if auth {
            try createAuthFile(codexHome: codexHome)
        }

        return CodexCLIConfiguration(
            executableURL: executableURL,
            model: "gpt-5.4-mini",
            homeDirectory: home,
            codexHomeDirectory: codexHome
        )
    }

    func executable(_ name: String) throws -> URL {
        let url = root.appending(path: name)
        try makeExecutable(at: url)
        return url
    }

    func makeExecutable(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    func createAuthFile(codexHome: URL? = nil) throws {
        let directory = codexHome ?? home.appending(path: ".codex", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: directory.appending(path: "auth.json").path(percentEncoded: false),
            contents: Data("{}".utf8)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

struct CommandCall: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    let stdin: Data
    let environment: [String: String]
    let timeout: TimeInterval
}

actor RecordingCommandRunner: CommandRunning {
    enum Behavior: Equatable, Sendable {
        case writeOutput(String)
        case writeOutputWithStderr(String, String)
        case stdout(String)
        case missingOutput(exitCode: Int32, stderr: String)
        case failure(CommandRunnerError)
    }

    private let behavior: Behavior
    private(set) var calls: [CommandCall] = []

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func run(
        executableURL: URL,
        arguments: [String],
        stdin: Data,
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> CommandResult {
        calls.append(CommandCall(
            executableURL: executableURL,
            arguments: arguments,
            stdin: stdin,
            environment: environment,
            timeout: timeout
        ))

        switch behavior {
        case .writeOutput(let output):
            return CommandResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data())
        case .writeOutputWithStderr(let output, let stderr):
            return CommandResult(exitCode: 0, stdout: Data(output.utf8), stderr: Data(stderr.utf8))
        case .stdout(let stdout):
            return CommandResult(exitCode: 0, stdout: Data(stdout.utf8), stderr: Data())
        case .missingOutput(let exitCode, let stderr):
            return CommandResult(exitCode: exitCode, stdout: Data(), stderr: Data(stderr.utf8))
        case .failure(let error):
            throw error
        }
    }
}
