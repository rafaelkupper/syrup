import Foundation
import Testing
@testable import Syrup

struct ClaudeCLITransformerTests {
    private func configuration(model: String = "sonnet", folder: URL? = nil) -> ClaudeCLIConfiguration {
        ClaudeCLIConfiguration(
            executableURL: URL(filePath: "/fixture/claude"), model: model,
            homeDirectory: URL(filePath: "/Users/fixture", directoryHint: .isDirectory),
            userName: "fixture", configDirectory: folder
        )
    }

    @Test func invocationHasNoToolsNoCustomizationsAndNoSavedSession() {
        #expect(ClaudeCLITransformer.arguments(model: "sonnet") == [
            "-p", "--output-format", "text",
            "--model", "sonnet",
            "--tools", "",
            "--strict-mcp-config",
            "--safe-mode",
            "--disable-slash-commands",
            "--permission-mode", "dontAsk",
            "--no-session-persistence",
            "--effort", "low",
            "--system-prompt", ClaudeCLITransformer.systemPrompt,
        ])
        #expect(ClaudeCLITransformer.arguments(model: "").contains("--model") == false)
    }

    @Test func environmentCarriesOnlyTheSignInLookupAndNeverAnAPIKey() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "SyrupClaudeConfig.\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = try executableFixture()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }

        let resolved = try ClaudeCLIConfigurationResolver.configuration(
            configuredPath: executable.path(percentEncoded: false), modelName: " haiku ",
            configDirectory: folder.path(percentEncoded: false) + "/",
            environment: ["HOME": "/Users/fixture", "USER": "fixture", "ANTHROPIC_API_KEY": "sk-fixture-not-a-key"]
        )

        #expect(resolved.model == "haiku")
        #expect(resolved.processEnvironment == [
            "HOME": "/Users/fixture", "USER": "fixture", "LOGNAME": "fixture",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "CLAUDE_CONFIG_DIR": ClaudeCLIConfiguration.plainPath(folder),
        ])
        // A trailing slash makes Claude look up a different, signed-out account.
        #expect(resolved.processEnvironment["CLAUDE_CONFIG_DIR"]?.hasSuffix("/") == false)
        #expect(resolved.processEnvironment["HOME"] == "/Users/fixture")
    }

    @Test func accountFolderComesFromTheSettingThenTheLaunchEnvironmentAndMustExist() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "SyrupClaudeHome.\(UUID())", directoryHint: .isDirectory)
        let folder = home.appending(path: ".claude-work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let executable = try executableFixture()
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let path = executable.path(percentEncoded: false)
        let environment = ["HOME": home.path(percentEncoded: false), "USER": "fixture"]

        let fromTilde = try ClaudeCLIConfigurationResolver.configuration(
            configuredPath: path, modelName: "", configDirectory: "~/.claude-work", environment: environment
        )
        #expect(fromTilde.configDirectory?.standardizedFileURL == folder.standardizedFileURL)

        let fromLaunch = try ClaudeCLIConfigurationResolver.configuration(
            configuredPath: path, modelName: "", configDirectory: "",
            environment: environment.merging(["CLAUDE_CONFIG_DIR": folder.path(percentEncoded: false)]) { $1 }
        )
        #expect(fromLaunch.configDirectory?.standardizedFileURL == folder.standardizedFileURL)

        let unset = try ClaudeCLIConfigurationResolver.configuration(
            configuredPath: path, modelName: "", configDirectory: "", environment: environment
        )
        #expect(unset.configDirectory == nil)

        // Claude would create a missing folder and report it signed out, so Syrup never launches it.
        #expect(throws: TranslationError.claudeNotSignedIn) {
            try ClaudeCLIConfigurationResolver.configuration(
                configuredPath: path, modelName: "", configDirectory: "~/.claude-typo", environment: environment
            )
        }
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".claude-typo").path(percentEncoded: false)) == false)
    }

    @Test func aMissingExecutableIsReportedAsNotFound() {
        #expect(throws: TranslationError.claudeCLINotFound) {
            try ClaudeCLIConfigurationResolver.configuration(
                configuredPath: "/nonexistent/claude", modelName: "", configDirectory: "",
                environment: ["HOME": "/nonexistent", "USER": "fixture"]
            )
        }
        #expect(throws: TranslationError.claudeCLINotFound) {
            try ClaudeCLIConfigurationResolver.executableURL(
                configuredPath: "", homeDirectory: URL(filePath: "/nonexistent"), candidatePaths: []
            )
        }
    }

    @Test func transformSendsTheFencedPromptOnStdinFromAPrivateFolder() async throws {
        let runner = ClaudeRunner(.init(exitCode: 0, stdout: Data("  \"Good morning\"  \n".utf8), stderr: Data()))
        let transformer = ClaudeCLITransformer(configuration: configuration(), commandRunner: runner, timeoutInterval: 9)

        let output = try await transformer.transform("bom dia", instruction: "Translate to English.")

        #expect(output == "Good morning")
        let call = try #require(await runner.calls.first)
        #expect(call.arguments == ClaudeCLITransformer.arguments(model: "sonnet"))
        #expect(call.arguments.joined().contains("bom dia") == false)
        #expect(call.arguments.joined().contains("Translate to English.") == false)
        let stdin = String(decoding: call.stdin, as: UTF8.self)
        #expect(stdin.hasPrefix("Translate to English."))
        #expect(stdin.contains("BEGIN INPUT"))
        #expect(stdin.contains("bom dia"))
        let directory = try #require(call.currentDirectory)
        #expect(directory.lastPathComponent.hasPrefix("SyrupClaude."))
        #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) == false)
        #expect(call.timeout == 9)
    }

    @Test(arguments: [
        ("Not logged in · Please run /login", TranslationError.claudeNotSignedIn),
        ("Claude AI usage limit reached|1731000000", .claudeUsageLimit),
        ("API Error: 500 something broke", .claudeFailed(1)),
    ])
    func failuresMapToOneMessageEach(output: String, expected: TranslationError) async {
        let runner = ClaudeRunner(.init(exitCode: 1, stdout: Data(output.utf8), stderr: Data()))
        let transformer = ClaudeCLITransformer(configuration: configuration(), commandRunner: runner)
        await #expect(throws: expected) {
            try await transformer.transform("text", instruction: "Polish it.")
        }
    }

    @Test func emptyOutputAndTimeoutAreTheirOwnErrors() async {
        let empty = ClaudeCLITransformer(
            configuration: configuration(),
            commandRunner: ClaudeRunner(.init(exitCode: 0, stdout: Data(" \n".utf8), stderr: Data()))
        )
        await #expect(throws: TranslationError.claudeEmptyOutput) {
            try await empty.transform("text", instruction: "Polish it.")
        }
        let slow = ClaudeCLITransformer(configuration: configuration(), commandRunner: ClaudeRunner(timesOut: true))
        await #expect(throws: TranslationError.claudeTimedOut) {
            try await slow.transform("text", instruction: "Polish it.")
        }
    }

    @Test func statusReadsOnlyWhetherItIsSignedIn() {
        func status(_ json: String) -> ClaudeCLIStatus {
            ClaudeCLIStatusChecker.status(from: CommandResult(exitCode: 0, stdout: Data(json.utf8), stderr: Data()))
        }
        #expect(status(#"{"loggedIn":true,"authMethod":"claude.ai","email":"someone@example.com"}"#)
            == ClaudeCLIStatus(kind: .ready, message: "signed in with your Claude plan"))
        #expect(status(#"{"loggedIn":false,"authMethod":"none"}"#).kind == .notSignedIn)
        #expect(status("not json").kind == .failed)
    }

    private func executableFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SyrupClaudeBin.\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "claude")
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }
}

struct CodexModelChoiceTests {
    @Test func catalogListsVisibleModelsInPriorityOrder() throws {
        let json = #"""
        {"models":[
          {"slug":"gpt-b","display_name":"GPT B","visibility":"list","priority":2},
          {"slug":"hidden","display_name":"Hidden","visibility":"hide","priority":0},
          {"slug":"gpt-a","display_name":"GPT A","visibility":"list","priority":1},
          {"slug":"gpt-c","visibility":"list","priority":3,"extra":{"ignored":true}}
        ]}
        """#
        let models = try #require(CodexModelCatalog.parse(Data(json.utf8)))
        #expect(models == [
            CodexModel(slug: "gpt-a", displayName: "GPT A"),
            CodexModel(slug: "gpt-b", displayName: "GPT B"),
            CodexModel(slug: "gpt-c", displayName: "gpt-c"),
        ])
        #expect(CodexModelCatalog.parse(Data("nope".utf8)) == nil)
        #expect(CodexModelCatalog.parse(Data(#"{"models":[]}"#.utf8)) == nil)
    }

    @Test func theAccountDefaultLeavesTheModelFlagOut() {
        let directory = URL(filePath: "/tmp/fixture")
        let output = URL(filePath: "/tmp/fixture/out.txt")
        #expect(CodexCLITransformer.arguments(workingDirectory: directory, model: "", outputFile: output).contains("--model") == false)
        let chosen = CodexCLITransformer.arguments(workingDirectory: directory, model: "gpt-a", outputFile: output)
        let index = chosen.firstIndex(of: "--model")
        #expect(index.map { chosen[$0 + 1] } == "gpt-a")
    }

    @Test func aSavedModelMissingFromTheListShowsAsCustom() {
        let choices = [CLIModelChoice(id: "gpt-a", title: "GPT A")]
        #expect(CLIModelChoice.isCustom("", in: choices) == false)
        #expect(CLIModelChoice.isCustom("gpt-a", in: choices) == false)
        #expect(CLIModelChoice.isCustom("gpt-5.4-mini", in: choices))
    }

    @MainActor
    @Test func newSettingsUseTheAccountDefaultModel() throws {
        let suite = "SyrupCodexDefault.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        #expect(settings.codexModel.isEmpty)
        #expect(settings.claudeModel == "sonnet")
        #expect(settings.claudeConfigDirectory.isEmpty)
    }
}

@MainActor
struct OfferedProviderTests {
    private func settings() throws -> (AppSettings, UserDefaults, String) {
        let suite = "SyrupOfferedProviders.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" }), defaults, suite)
    }

    @Test func claudeCodeIsOfferedOnlyWhenInstalledOrAlreadyInUse() throws {
        let (settings, defaults, suite) = try settings()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(settings.offeredProviders(claudeInstalled: false).contains(.claudeCLI) == false)
        #expect(settings.offeredProviders(claudeInstalled: true).contains(.claudeCLI))

        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.translationProvider = .claudeCLI }
        #expect(settings.offeredProviders(claudeInstalled: false).contains(.claudeCLI))

        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.translationProvider = nil }
        settings.translationProvider = .claudeCLI
        #expect(settings.offeredProviders(claudeInstalled: false).contains(.claudeCLI))
    }

    @Test func commandLineProvidersNeverSendUnfinishedTranscripts() {
        #expect(TranslationProvider.claudeCLI.isCommandLine)
        #expect(TranslationProvider.codexCLI.isCommandLine)
        #expect(TranslationProvider.openAICompatible.isCommandLine == false)
        #expect(TranslationProvider.claudeCLI.supportsSpokenEdits)
    }
}

private actor ClaudeRunner: CommandRunning {
    struct Call: Sendable {
        let arguments: [String]
        let stdin: Data
        let environment: [String: String]
        let currentDirectory: URL?
        let timeout: TimeInterval
    }

    private let result: CommandResult?
    private(set) var calls: [Call] = []

    init(_ result: CommandResult) { self.result = result }
    init(timesOut: Bool) { result = nil }

    func run(
        executableURL: URL, arguments: [String], stdin: Data, environment: [String: String], timeout: TimeInterval
    ) async throws -> CommandResult {
        try await run(
            executableURL: executableURL, arguments: arguments, stdin: stdin,
            environment: environment, currentDirectory: nil, timeout: timeout
        )
    }

    func run(
        executableURL: URL, arguments: [String], stdin: Data, environment: [String: String],
        currentDirectory: URL?, timeout: TimeInterval
    ) async throws -> CommandResult {
        calls.append(Call(
            arguments: arguments, stdin: stdin, environment: environment,
            currentDirectory: currentDirectory, timeout: timeout
        ))
        guard let result else { throw CommandRunnerError.timedOut }
        return result
    }
}
