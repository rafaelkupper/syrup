import AppKit
import SwiftUI

/// Sections for the writing provider, shown in Models.
struct ProviderSections: View {
    @Bindable var settings: AppSettings
    let keychainStore: KeychainStore
    let endpointTester = OpenAICompatibleEndpointTester()
    let codexStatusChecker = CodexCLIStatusChecker()
    @State private var apiKeyInput = ""
    @State private var hasStoredAPIKey = false
    @State private var isEditingAPIKey = false
    @State private var connectionTest = EndpointConnectionTest()
    @State private var codexStatus: CodexCLIStatus?
    @State private var isCheckingCodexStatus = false

    var body: some View {
        Group {
            providerSection

            switch settings.translationProvider {
            case .openAICompatible:
                endpointSection
            case .codexCLI:
                codexSection
            case .appleOnDevice:
                appleSection
            }
        }
        .onChange(of: settings.baseURL) { connectionTest.invalidate() }
        .onChange(of: settings.modelName) { connectionTest.invalidate() }
        .onChange(of: settings.translationProvider) { connectionTest.invalidate() }
        .onChange(of: apiKeyInput) { connectionTest.invalidate() }
        .onAppear {
            loadAPIKeyState()
            refreshCodexStatusIfNeeded()
        }
    }

    // MARK: - Provider choice

    private var providerSection: some View {
        Section {
            providerRow(
                .openAICompatible,
                tag: TagBadge(text: "Cloud or local server", color: .secondary),
                description: "Fastest. OpenAI, OpenRouter, Cerebras, Ollama, LM Studio, and others."
            )
            providerRow(
                .appleOnDevice,
                tag: TagBadge(text: "Private · Offline", color: .green),
                description: "Runs on this Mac with Apple Intelligence. Nothing leaves the Mac."
            )
            providerRow(
                .codexCLI,
                tag: TagBadge(text: "Slower", color: .orange),
                description: "Uses your ChatGPT plan through the Codex CLI, with no API key."
            )
        } header: {
            HStack {
                Text("Writing")
                Spacer()
                Text("Translates and rewrites. Workflows use this unless they pick another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func providerRow(
        _ provider: TranslationProvider,
        tag: TagBadge,
        description: String
    ) -> some View {
        let isSelected = settings.translationProvider == provider
        return Button {
            settings.translationProvider = provider
            refreshCodexStatusIfNeeded()
        } label: {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: isSelected ? "inset.filled.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(provider.displayName)
                        tag
                    }
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - OpenAI-compatible

    @ViewBuilder
    private var endpointSection: some View {
        Section("OpenAI-compatible server") {
            LabeledContent("Base URL") {
                TextField("Base URL", text: $settings.baseURL)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 260)
            }

            if EndpointPolicy.isUnencryptedRemote(settings.baseURL) {
                Label(
                    "This server uses http, so your API key and text travel unencrypted. Use https unless the server is on a network you trust.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            LabeledContent("Model") {
                TextField("Model", text: $settings.modelName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 260)
            }

            if isEditingAPIKey {
                LabeledContent("New API key") {
                    HStack(spacing: 8) {
                        SecureField("sk-…", text: $apiKeyInput)
                            .labelsHidden()
                            .frame(width: 220)
                            .onSubmit(saveAPIKey)
                        Button("Save", action: saveAPIKey)
                            .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancel") {
                            apiKeyInput = ""
                            isEditingAPIKey = false
                        }
                    }
                }
            } else {
                LabeledContent {
                    HStack(spacing: 8) {
                        StatusPill(
                            text: hasStoredAPIKey ? "Saved" : "Not set",
                            tone: hasStoredAPIKey ? .ok : .neutral
                        )
                        Button(hasStoredAPIKey ? "Change…" : "Add…") {
                            isEditingAPIKey = true
                        }
                        if hasStoredAPIKey {
                            Button("Remove", action: deleteAPIKey)
                        }
                    }
                } label: {
                    Text("API key")
                    Text("Kept in Syrup's own store on this Mac")
                }
            }

            LabeledContent {
                Button("Test Connection", action: testEndpoint)
                    .disabled(connectionTest.status == .testing)
            } label: {
                Text("Connection")
                endpointStatusText
            }
        }
    }

    @ViewBuilder
    private var endpointStatusText: some View {
        switch connectionTest.status {
        case .idle:
            Text("Checks that the URL, model, and key work together")
        case .saved(let message):
            Label(message, systemImage: "checkmark")
                .foregroundStyle(.green)
        case .testing:
            Text("Testing…")
        case .success:
            Label("The server answered", systemImage: "checkmark")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark")
                .foregroundStyle(.red)
        }
    }

    // MARK: - Codex CLI

    private var codexSection: some View {
        Section("Codex CLI") {
            LabeledContent("Executable") {
                HStack(spacing: 8) {
                    TextField("Codex path", text: $settings.codexPath)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 260)
                    Button("Detect", action: detectCodexCLI)
                }
            }

            LabeledContent("Model") {
                TextField("Model", text: $settings.codexModel)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 260)
            }

            LabeledContent {
                Button("Check Status", action: refreshCodexStatus)
                    .disabled(isCheckingCodexStatus)
            } label: {
                Text("Status")
                codexStatusText
            }
        }
    }

    @ViewBuilder
    private var codexStatusText: some View {
        if isCheckingCodexStatus {
            Text("Checking Codex CLI…")
        } else if let codexStatus {
            switch codexStatus.kind {
            case .ready:
                Label(codexStatus.message, systemImage: "checkmark")
                    .foregroundStyle(.green)
            case .notFound, .notSignedIn, .failed:
                Label(codexStatus.message, systemImage: "xmark")
                    .foregroundStyle(.red)
            }
        } else {
            Text("Not checked yet")
        }
    }

    // MARK: - Apple On-Device

    private var appleSection: some View {
        Section("Apple Intelligence") {
            LabeledContent {
                Button("Open Apple Intelligence Settings…") {
                    openSystemSettings("x-apple.systempreferences:com.apple.Apple-Intelligence-Settings.extension")
                }
            } label: {
                Text("Availability")
                Text(AppleOnDeviceTransformer.availabilityMessage())
            }
        }
    }

    // MARK: - Actions

    private func loadAPIKeyState() {
        Task { @MainActor in
            do {
                hasStoredAPIKey = try await Task.detached(priority: .userInitiated) { [keychainStore] in
                    try keychainStore.load()?.isEmpty == false
                }.value
            } catch {
                connectionTest.show(.failure(userMessage(for: error)))
            }
        }
    }

    private func saveAPIKey() {
        let trimmedAPIKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedAPIKey.isEmpty == false else { return }
        connectionTest.invalidate()
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) { [keychainStore] in
                    try keychainStore.save(trimmedAPIKey)
                }.value
                hasStoredAPIKey = true
                apiKeyInput = ""
                isEditingAPIKey = false
                connectionTest.show(.saved("API key saved"))
            } catch {
                connectionTest.show(.failure(userMessage(for: error)))
            }
        }
    }

    private func deleteAPIKey() {
        connectionTest.invalidate()
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) { [keychainStore] in
                    try keychainStore.delete()
                }.value
                hasStoredAPIKey = false
                apiKeyInput = ""
                connectionTest.show(.saved("API key removed"))
            } catch {
                connectionTest.show(.failure(userMessage(for: error)))
            }
        }
    }

    private func testEndpoint() {
        let baseURL = settings.baseURL
        let modelName = settings.modelName
        let typedAPIKey = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = connectionTest.begin()
        Task { @MainActor in
            await connectionTest.run(request) {
                let configuration = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
                    baseURLString: baseURL,
                    modelName: modelName,
                    typedAPIKey: typedAPIKey,
                    keychainStore: keychainStore
                )
                try await endpointTester.testConnection(configuration: configuration)
            }
        }
    }

    private func detectCodexCLI() {
        do {
            let homeDirectory = URL(
                filePath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
                directoryHint: .isDirectory
            )
            let executableURL = try CodexCLIConfigurationResolver.executableURL(
                configuredPath: "",
                homeDirectory: homeDirectory
            )
            settings.codexPath = executableURL.path(percentEncoded: false)
            refreshCodexStatus()
        } catch {
            codexStatus = CodexCLIStatus(kind: .notFound, message: "not found")
        }
    }

    private func refreshCodexStatusIfNeeded() {
        guard settings.translationProvider == .codexCLI else { return }
        refreshCodexStatus()
    }

    private func refreshCodexStatus() {
        guard isCheckingCodexStatus == false else { return }

        let codexPath = settings.codexPath
        let codexModel = settings.codexModel
        isCheckingCodexStatus = true

        Task { @MainActor in
            codexStatus = await codexStatusChecker.status(
                configuredPath: codexPath,
                modelName: codexModel
            )
            isCheckingCodexStatus = false
        }
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
