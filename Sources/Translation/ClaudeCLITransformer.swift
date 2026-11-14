import Foundation

struct ClaudeCLIConfiguration: Equatable, Sendable {
    let executableURL: URL
    /// An alias (`sonnet`) or a full model name. Empty leaves `--model` out.
    let model: String
    let homeDirectory: URL
    let userName: String
    /// `CLAUDE_CONFIG_DIR`. Nil means Claude's default, `~/.claude`.
    let configDirectory: URL?

    /// Only what Claude needs to find its sign-in: `USER` names the Keychain item, and the config folder
    /// picks the account. Nothing else from Syrup's environment reaches it, so a stray
    /// `ANTHROPIC_API_KEY` cannot switch billing.
    var processEnvironment: [String: String] {
        var environment = [
            "HOME": Self.plainPath(homeDirectory),
            "USER": userName,
            "LOGNAME": userName,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        ]
        if let configDirectory {
            environment["CLAUDE_CONFIG_DIR"] = Self.plainPath(configDirectory)
        }
        return environment
    }

    /// No trailing slash: Claude keys its Keychain sign-in by the exact folder string, so
    /// `~/.claude-work/` reads as a different, signed-out account than `~/.claude-work`.
    static func plainPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

enum ClaudeCLIConfigurationResolver {
    static func configuration(
        configuredPath: String,
        modelName: String,
        configDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        candidatePaths: [String]? = nil
    ) throws -> ClaudeCLIConfiguration {
        let homeDirectory = URL(
            filePath: environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? NSHomeDirectory(),
            directoryHint: .isDirectory
        )
        let executableURL = try executableURL(
            configuredPath: configuredPath, homeDirectory: homeDirectory,
            fileManager: fileManager, candidatePaths: candidatePaths
        )
        let folder = try resolvedConfigDirectory(
            configDirectory, environment: environment, homeDirectory: homeDirectory, fileManager: fileManager
        )
        let userName = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        return ClaudeCLIConfiguration(
            executableURL: executableURL,
            model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            homeDirectory: homeDirectory,
            userName: userName,
            configDirectory: folder
        )
    }

    static func executableURL(
        configuredPath: String,
        homeDirectory: URL,
        fileManager: FileManager = .default,
        candidatePaths: [String]? = nil
    ) throws -> URL {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            guard trimmed.hasPrefix("/"), fileManager.isExecutableFile(atPath: trimmed) else {
                throw TranslationError.claudeCLINotFound
            }
            return URL(filePath: trimmed)
        }
        let candidates = candidatePaths ?? [
            homeDirectory.appending(path: ".local/bin/claude").path(percentEncoded: false),
            homeDirectory.appending(path: ".claude/local/claude").path(percentEncoded: false),
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        guard let found = CommandLocator.find(
            "claude", homeDirectory: homeDirectory, fileManager: fileManager, candidatePaths: candidates
        ) else {
            throw TranslationError.claudeCLINotFound
        }
        return found
    }

    /// Whether Claude Code is installed where Syrup looks for it. Settings lists the provider only then.
    static func isInstalled(configuredPath: String, fileManager: FileManager = .default) -> Bool {
        let home = URL(filePath: NSHomeDirectory(), directoryHint: .isDirectory)
        return (try? executableURL(configuredPath: configuredPath, homeDirectory: home, fileManager: fileManager)) != nil
    }

    /// The setting wins, then a `CLAUDE_CONFIG_DIR` Syrup was launched with. Claude creates a folder it
    /// is pointed at, so a configured folder that does not exist fails here instead of becoming an
    /// empty, signed-out account.
    private static func resolvedConfigDirectory(
        _ configured: String, environment: [String: String], homeDirectory: URL, fileManager: FileManager
    ) throws -> URL? {
        let setting = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = setting.isEmpty
            ? environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            : setting
        guard raw.isEmpty == false else { return nil }
        let path = raw == "~" ? homeDirectory.path(percentEncoded: false)
            : raw.hasPrefix("~/") ? homeDirectory.appending(path: String(raw.dropFirst(2))).path(percentEncoded: false)
            : raw
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw TranslationError.claudeNotSignedIn
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}

/// Runs `claude -p` once per transformation. Claude only rewrites text here, so it starts with no tools,
/// no MCP servers, no CLAUDE.md, skills, plugins, or hooks (`--safe-mode`), no slash commands, nothing
/// that could ask for permission, and no saved session. The input is fenced as data on stdin.
struct ClaudeCLITransformer: TextTransformer {
    private let configuration: ClaudeCLIConfiguration
    private let commandRunner: any CommandRunning
    private let timeoutInterval: TimeInterval

    init(
        configuration: ClaudeCLIConfiguration,
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        timeoutInterval: TimeInterval = 60
    ) {
        self.configuration = configuration
        self.commandRunner = commandRunner
        self.timeoutInterval = timeoutInterval
    }

    /// Fixed text only; the run's instruction and input go on stdin, never in argv.
    static let systemPrompt = """
        You transform text for a dictation app. Follow the instructions in the user's message and reply \
        with only the resulting text: no preamble, notes, or explanation. You have no tools.
        """

    static let restrictions: [String] = [
        "--tools", "",
        "--strict-mcp-config",
        "--safe-mode",
        "--disable-slash-commands",
        "--permission-mode", "dontAsk",
        "--no-session-persistence",
    ]

    static func arguments(model: String) -> [String] {
        ["-p", "--output-format", "text"]
            + (model.isEmpty ? [] : ["--model", model])
            + restrictions
            + ["--effort", "low", "--system-prompt", systemPrompt]
    }

    func transform(_ text: String, instruction: String) async throws -> String {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SyrupClaude.\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let prompt = PromptBuilder.fencedPrompt(instruction: instruction, transcript: text)
        let result: CommandResult
        do {
            result = try await commandRunner.run(
                executableURL: configuration.executableURL,
                arguments: Self.arguments(model: configuration.model),
                stdin: Data(prompt.utf8),
                environment: configuration.processEnvironment,
                currentDirectory: workingDirectory,
                timeout: timeoutInterval
            )
        } catch CommandRunnerError.timedOut {
            throw TranslationError.claudeTimedOut
        }

        let stdout = String(decoding: result.stdout, as: UTF8.self)
        guard result.exitCode == 0 else {
            throw Self.failure(exitCode: result.exitCode, output: stdout + "\n" + String(decoding: result.stderr, as: UTF8.self))
        }
        let normalized = ModelOutputNormalizer.normalize(
            stdout,
            keepsWrapperQuotes: ModelOutputNormalizer.requestsQuotes(input: text, instruction: instruction)
        )
        guard normalized.isEmpty == false else { throw TranslationError.claudeEmptyOutput }
        return normalized
    }

    /// Claude reports a missing sign-in and plan limits as text with a non-zero exit.
    static func failure(exitCode: Int32, output: String) -> TranslationError {
        let lowercased = output.lowercased()
        if lowercased.contains("not logged in") || lowercased.contains("/login")
            || lowercased.contains("invalid api key") || lowercased.contains("oauth token") {
            return .claudeNotSignedIn
        }
        if lowercased.contains("usage limit") || lowercased.contains("rate limit")
            || lowercased.contains("limit reached") || lowercased.contains("out of extra usage") {
            return .claudeUsageLimit
        }
        return .claudeFailed(Int(exitCode))
    }
}

/// What Settings shows for Claude Code, from `claude auth status`.
struct ClaudeCLIStatus: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case ready, notFound, notSignedIn, failed }
    let kind: Kind
    let message: String
}

struct ClaudeCLIStatusChecker: Sendable {
    private let commandRunner: any CommandRunning
    private let timeoutInterval: TimeInterval

    init(commandRunner: any CommandRunning = ProcessCommandRunner(), timeoutInterval: TimeInterval = 10) {
        self.commandRunner = commandRunner
        self.timeoutInterval = timeoutInterval
    }

    func status(
        configuredPath: String,
        configDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> ClaudeCLIStatus {
        let configuration: ClaudeCLIConfiguration
        do {
            configuration = try ClaudeCLIConfigurationResolver.configuration(
                configuredPath: configuredPath, modelName: "", configDirectory: configDirectory, environment: environment
            )
        } catch TranslationError.claudeCLINotFound {
            return ClaudeCLIStatus(kind: .notFound, message: "not found")
        } catch {
            return ClaudeCLIStatus(kind: .notSignedIn, message: "that account folder doesn't exist")
        }
        guard let result = try? await commandRunner.run(
            executableURL: configuration.executableURL,
            arguments: ["auth", "status"],
            stdin: Data(),
            environment: configuration.processEnvironment,
            timeout: timeoutInterval
        ) else {
            return ClaudeCLIStatus(kind: .failed, message: "status unavailable")
        }
        return Self.status(from: result)
    }

    /// Reads only `loggedIn` and `authMethod`. The account's email and organization stay unread.
    static func status(from result: CommandResult) -> ClaudeCLIStatus {
        struct AuthStatus: Decodable {
            let loggedIn: Bool
            let authMethod: String?
        }
        guard let status = try? JSONDecoder().decode(AuthStatus.self, from: result.stdout) else {
            return ClaudeCLIStatus(kind: .failed, message: "status unavailable")
        }
        guard status.loggedIn else {
            return ClaudeCLIStatus(kind: .notSignedIn, message: "not signed in - run `claude` in Terminal and sign in")
        }
        let method = switch status.authMethod {
        case "claude.ai": "your Claude plan"
        case "api_key", "apiKey": "an API key"
        default: "Claude"
        }
        return ClaudeCLIStatus(kind: .ready, message: "signed in with \(method)")
    }

    /// The models Claude Code accepts by alias, newest family first. Claude has no catalog command, so
    /// any other name goes in the custom field.
    static let modelAliases: [(alias: String, name: String)] = [
        ("haiku", "Haiku (fastest)"),
        ("sonnet", "Sonnet"),
        ("opus", "Opus"),
        ("fable", "Fable"),
    ]
}
