import Foundation

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
        var environment = [
            "HOME": homeDirectory.path(percentEncoded: false),
            "PATH": CommandLocator.childPath(for: executableURL),
        ]
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
    /// leaves `--model` out, so Codex uses the account's default. The result is read from stdout, which
    /// carries only the final message, so no result file is ever written to disk.
    static func arguments(workingDirectory: URL, model: String) -> [String] {
        ["exec", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config"]
            + restrictions
            + ["--cd", workingDirectory.path(percentEncoded: false)]
            + (model.isEmpty ? [] : ["--model", model])
            + ["-"]
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

        let boundary = UUID().uuidString
        let prompt = PromptBuilder.fencedPrompt(
            instruction: instruction,
            transcript: text,
            boundary: boundary
        )
        let arguments = Self.arguments(workingDirectory: temporaryDirectory, model: configuration.model)

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
        } catch CommandRunnerError.outputTooLarge {
            throw TranslationError.cliOutputTooLarge(.codexCLI)
        }

        try Self.mapFailureIfNeeded(result, inputBoundary: boundary)

        let output = String(decoding: result.stdout, as: UTF8.self)
        let normalizedOutput = ModelOutputNormalizer.normalize(
            output,
            keepsWrapperQuotes: ModelOutputNormalizer.requestsQuotes(input: text, instruction: instruction)
        )
        guard normalizedOutput.isEmpty == false else {
            throw TranslationError.codexEmptyOutput
        }

        return normalizedOutput
    }

    /// Codex echoes the prompt to stderr before its own messages, so only what follows the input's
    /// closing marker is matched: a dictation that mentions "rate limit" must not read as a plan limit.
    /// The marker carries a random boundary the input cannot forge. Without it (no echo, or the echo
    /// fell out of the kept tail), everything kept is Codex's own output.
    static func codexMessages(in stderr: Data, inputBoundary: String) -> String {
        let text = String(decoding: stderr, as: UTF8.self)
        guard let marker = text.range(of: "END INPUT \(inputBoundary)", options: .backwards) else { return text }
        return String(text[marker.upperBound...])
    }

    private static func mapFailureIfNeeded(_ result: CommandResult, inputBoundary: String) throws {
        guard result.exitCode != 0 else { return }

        let lowercasedStderr = codexMessages(in: result.stderr, inputBoundary: inputBoundary).lowercased()

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

        if result.exitCode == CommandLocator.interpreterNotFoundExitCode {
            throw TranslationError.cliCouldNotStart(.codexCLI)
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
