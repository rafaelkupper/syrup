import Foundation
import Testing
@testable import Syrup

/// The process runner both command-line providers use, run against real `/bin/sh` children.
struct CommandRunnerTests {
    private let runner = ProcessCommandRunner(killGraceNanoseconds: 100_000_000)

    private func sh(_ script: String, timeout: TimeInterval = 5) async throws -> CommandResult {
        try await runner.run(
            executableURL: URL(filePath: "/bin/sh"), arguments: ["-c", script], stdin: Data(),
            environment: ["PATH": "/usr/bin:/bin"], timeout: timeout
        )
    }

    @Test func aHelperThatKeepsTheOutputOpenDoesNotHoldTheResult() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await sh("/bin/sleep 3 & echo done")
        #expect(result.exitCode == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "done\n")
        #expect(started.duration(to: clock.now) < .seconds(2))
    }

    @Test func theTimeoutBoundsTheCallEvenWhenAHelperKeepsTheOutputOpen() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: CommandRunnerError.timedOut) {
            _ = try await sh("/bin/sleep 3 & /bin/sleep 3", timeout: 0.1)
        }
        #expect(started.duration(to: clock.now) < .seconds(2))
    }

    /// A CLI that started a helper: stopping the run stops the helper too, not just the CLI.
    @MainActor @Test func aTimeoutAlsoStopsTheHelpersTheCLIStarted() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "SyrupHelper.\(UUID()).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        await #expect(throws: CommandRunnerError.timedOut) {
            _ = try await runner.run(
                executableURL: URL(filePath: "/bin/sh"),
                arguments: ["-c", #"/bin/sleep 30 & echo $! > "$PIDFILE"; /bin/sleep 30"#], stdin: Data(),
                environment: ["PATH": "/usr/bin:/bin", "PIDFILE": pidFile.path(percentEncoded: false)], timeout: 0.3
            )
        }
        let helper = try #require(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        // A killed helper is gone once launchd has reaped it.
        await eventually("The helper is still running") { kill(helper, 0) != 0 }
        #expect(kill(helper, 0) != 0)
    }

    @Test func runawayOutputIsStoppedAtTheLimit() async throws {
        await #expect(throws: CommandRunnerError.outputTooLarge) {
            _ = try await sh("/usr/bin/yes", timeout: 20)
        }
    }

    @Test func stderrKeepsItsEndWhereFailureMessagesAre() async throws {
        let result = try await sh("/usr/bin/yes x | /usr/bin/head -c 200000 >&2; echo 'Error: usage limit reached' >&2; exit 3")
        #expect(result.exitCode == 3)
        #expect(result.stderr.count <= ProcessCommandRunner.stderrLimit)
        #expect(String(decoding: result.stderr, as: UTF8.self).hasSuffix("Error: usage limit reached\n"))
    }

    @Test func aScriptLauncherFindsAnInterpreterBesideIt() async throws {
        // An npm install is a `#!/usr/bin/env node` script with `node` linked beside it.
        let folder = FileManager.default.temporaryDirectory.appending(path: "SyrupLauncher.\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let interpreter = folder.appending(path: "fake-node")
        try Data("#!/bin/sh\necho launched\n".utf8).write(to: interpreter)
        let launcher = folder.appending(path: "codex")
        try Data("#!/usr/bin/env fake-node\n".utf8).write(to: launcher)
        for file in [interpreter, launcher] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        }

        let withSystemPath = try await runner.run(
            executableURL: launcher, arguments: [], stdin: Data(),
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: 5
        )
        #expect(withSystemPath.exitCode == CommandLocator.interpreterNotFoundExitCode)

        let withChildPath = try await runner.run(
            executableURL: launcher, arguments: [], stdin: Data(),
            environment: ["PATH": CommandLocator.childPath(for: launcher)], timeout: 5
        )
        #expect(withChildPath.exitCode == 0)
        #expect(String(decoding: withChildPath.stdout, as: UTF8.self) == "launched\n")
    }

    @Test func childPathPutsTheExecutablesFolderFirstWithoutRepeats() {
        #expect(CommandLocator.childPath(for: URL(filePath: "/opt/homebrew/bin/codex"))
            == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        #expect(CommandLocator.childPath(for: URL(filePath: "/Users/x/.local/bin/claude"))
            == "/Users/x/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// A Codex configuration whose home has an auth file, so the transformer gets as far as running.
    private func signedInCodex(_ behavior: RecordingCommandRunner.Behavior) throws -> (CodexCLITransformer, URL) {
        let home = FileManager.default.temporaryDirectory.appending(path: "SyrupCodexHome.\(UUID())", directoryHint: .isDirectory)
        let auth = home.appending(path: ".codex/auth.json")
        try FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: auth)
        let transformer = CodexCLITransformer(
            configuration: CodexCLIConfiguration(
                executableURL: URL(filePath: "/fixture/codex"), model: "", homeDirectory: home, codexHomeDirectory: nil
            ),
            commandRunner: RecordingCommandRunner(behavior: behavior)
        )
        return (transformer, home)
    }

    @Test func exit127SaysTheLauncherCouldNotStart() async throws {
        #expect(ClaudeCLITransformer.failure(exitCode: 127, output: "env: node: No such file or directory")
            == .cliCouldNotStart(.claudeCLI))
        let (codex, home) = try signedInCodex(.missingOutput(exitCode: 127, stderr: "env: node: No such file or directory"))
        defer { try? FileManager.default.removeItem(at: home) }
        await #expect(throws: TranslationError.cliCouldNotStart(.codexCLI)) {
            try await codex.transform("text", instruction: "Polish it.")
        }
    }

    @Test func codexErrorsIgnoreTheUsersWordsInTheEchoedPrompt() async throws {
        // A short dictation fits wholly inside any fixed-size tail, so matching starts after the input.
        let (codex, home) = try signedInCodex(.echoPromptThenFail(exitCode: 1, message: "Error: model crashed"))
        defer { try? FileManager.default.removeItem(at: home) }
        await #expect(throws: TranslationError.codexFailed(1)) {
            try await codex.transform("fix the authentication and rate limit wording", instruction: "Polish it.")
        }

        let (signedOut, signedOutHome) = try signedInCodex(.echoPromptThenFail(exitCode: 1, message: "Error: not signed in, run codex login"))
        defer { try? FileManager.default.removeItem(at: signedOutHome) }
        await #expect(throws: TranslationError.codexNotSignedIn) {
            try await signedOut.transform("hello", instruction: "Polish it.")
        }
    }
}
