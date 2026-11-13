import AppKit
import KeyboardShortcuts
import SwiftUI

struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismissWindow) private var dismissWindow
    let state: AppState
    @Bindable var settings: AppSettings
    @Bindable var assetManager: TranscriberAssetManager
    let autoPaster: any AutoPasting
    let keychainStore: KeychainStore

    @State private var step = OnboardingStep.welcome
    @State private var permissions = PermissionStatusModel()
    @State private var isFreshInstall = OnboardingGate.isPending()
    @State private var didApplyRecipeDefaults = false

    @State private var apiKeyInput = ""
    @State private var hasStoredAPIKey = false
    @State private var isReplacingAPIKey = false
    @State private var connectionTest = EndpointConnectionTest()
    @State private var codexProblem: String?

    @State private var tasteStartedAt = Date.now
    @State private var isShowingShortcutPopover = false
    @State private var showsSprinkles = false

    private let focusController = SettingsWindowFocusController()
    private let endpointTester = OpenAICompatibleEndpointTester()
    private let codexStatusChecker = CodexCLIStatusChecker()

    private var palette: OnboardingPalette { .forScheme(colorScheme) }
    private var workflow: Workflow { settings.activeWorkflow }
    private var steps: [OnboardingStep] { OnboardingStep.steps(for: workflow.kind) }
    private var controls: ActiveWorkflowBindings { ActiveWorkflowBindings(state: state) }

    var body: some View {
        ZStack(alignment: .top) {
            palette.background

            DripBand()

            page
                .frame(width: 540, height: 356)
                .padding(.top, 44)
                .multilineTextAlignment(.center)

            if showsSprinkles {
                SyrupSprinkles()
            }
        }
        .frame(width: 540, height: 460)
        .overlay(alignment: .topTrailing) {
            if step != .taste {
                Button("Skip setup", action: finish)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(OnboardingPalette.buttonInk)
                    .padding(.top, 6)
                    .padding(.trailing, 14)
            }
        }
        .overlay(alignment: .bottom) {
            footer
        }
        .ignoresSafeArea()
        .frame(width: 540, height: 428)
        .font(.system(size: 13, design: .rounded))
        .foregroundStyle(palette.ink)
        .tint(OnboardingPalette.syrup)
        .onAppear {
            permissions.refresh(autoPaster: autoPaster)
            NSApp.activate()
            if isFreshInstall, AppleOnDeviceTransformer.availabilityMessage() == "Ready" {
                settings.translationProvider = .appleOnDevice
            }
        }
        .onDisappear {
            state.holdsPasteForOnboarding = false
            OnboardingGate.markDone()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh(autoPaster: autoPaster)
        }
        .onChange(of: step) { _, newStep in
            state.holdsPasteForOnboarding = newStep == .taste
            if newStep == .taste { tasteStartedAt = .now }
        }
        .onChange(of: tasteResult?.id) { _, id in
            if id != nil, tasteResultSucceeded { showSprinkles() }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: welcomePage
        case .permissions: permissionsPage
        case .recipe: recipePage
        case .flavor: flavorPage
        case .taste: tastePage
        }
    }

    // MARK: - Footer

    private var footer: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, item in
                    Circle()
                        .fill(index <= stepIndex ? OnboardingPalette.syrup : palette.off)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(item != step)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(stepIndex + 1) of \(steps.count)")

            HStack {
                if stepIndex > 0 {
                    Button(action: goBack) {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.secondaryInk)
                }
                Spacer()
                Button(primaryTitle, action: goForward)
                    .buttonStyle(SyrupButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

    private var primaryTitle: String {
        switch step {
        case .welcome:
            "Start pouring"
        case .permissions:
            permissions.microphone == .granted && permissions.speech == .granted ? "Continue" : "Skip for now"
        case .recipe, .flavor:
            "Continue"
        case .taste:
            tasteResultSucceeded ? "All done" : "Skip"
        }
    }

    private func goBack() {
        guard stepIndex > 0 else { return }
        step = steps[stepIndex - 1]
    }

    private func goForward() {
        switch step {
        case .permissions:
            if isFreshInstall, permissions.accessibility == .granted {
                settings.autoPasteEnabled = true
            }
            advance()
        case .flavor:
            Task {
                if await saveTypedAPIKey() { advance() }
            }
        case .taste:
            finish()
        case .welcome, .recipe:
            advance()
        }
    }

    private func advance() {
        guard stepIndex + 1 < steps.count else { return finish() }
        step = steps[stepIndex + 1]
    }

    private func finish() {
        OnboardingGate.markDone()
        dismissWindow(id: OnboardingWindow.id)
    }

    // MARK: - Shared pieces

    private func header(mood: SyrupDrop.Mood = .smiling, size: CGFloat = 40, title: String) -> some View {
        VStack(spacing: 8) {
            SyrupDrop(size: size, mood: mood)
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
        }
    }

    private func subtitle(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(palette.secondaryInk)
            .padding(.top, 4)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(palette.secondaryInk)
    }

    private func rowBackground(selected: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(palette.card)
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? OnboardingPalette.syrup : palette.line, lineWidth: selected ? 1.5 : 1)
            }
    }

    // MARK: - Welcome

    private var welcomePage: some View {
        VStack(spacing: 0) {
            FallingDrop(size: 88)
            Text("Hi, I’m Syrup!")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .padding(.top, 16)
            Text("Say it in your language, I’ll pour it out in another.")
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(palette.secondaryInk)
                .padding(.top, 6)
            note("Takes about a minute.")
                .padding(.top, 12)
        }
    }

    // MARK: - Permissions

    private var permissionsPage: some View {
        VStack(spacing: 0) {
            header(title: "Let me listen")
            VStack(spacing: 8) {
                permissionRow(
                    symbol: "mic",
                    title: "Microphone",
                    detail: "So I can hear you.",
                    status: permissions.microphone,
                    settingsPane: .microphone
                ) {
                    await PermissionActions.requestMicrophone()
                }
                permissionRow(
                    symbol: "waveform",
                    title: "Speech Recognition",
                    detail: "Turns your voice into text on this Mac.",
                    status: permissions.speech,
                    settingsPane: .speechRecognition
                ) {
                    await PermissionActions.requestSpeechRecognition()
                }
                permissionRow(
                    symbol: "text.cursor",
                    title: "Accessibility",
                    detail: "Pastes results where you’re typing.",
                    isOptional: true,
                    status: permissions.accessibility,
                    settingsPane: nil
                ) {
                    settings.autoPasteEnabled = true
                    autoPaster.requestTrust()
                }
            }
            .frame(width: 420)
            .padding(.top, 16)
            note("Your voice never leaves this Mac.")
                .padding(.top, 12)
        }
    }

    private func permissionRow(
        symbol: String,
        title: String,
        detail: String,
        isOptional: Bool = false,
        status: PermissionStatusModel.Status,
        settingsPane: PermissionActions.SettingsPane?,
        request: @escaping () async -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 28, height: 28)
                .background(palette.tint, in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(title)
                        .fontWeight(.semibold)
                    if isOptional {
                        Text("Optional")
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(palette.secondaryInk)
                    }
                }
                Text(detail)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(palette.secondaryInk)
            }

            Spacer(minLength: 8)

            switch status {
            case .granted:
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(palette.accent)
                    .padding(.trailing, 6)
                    .accessibilityLabel("Allowed")
            case .denied, .restricted:
                if let settingsPane {
                    Button("Open Settings") {
                        PermissionActions.open(settingsPane)
                    }
                    .buttonStyle(SyrupButtonStyle(height: 24))
                } else {
                    allowButton(title: title, request: request)
                }
            case .notRequested, .unknown:
                allowButton(title: title, request: request)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground())
    }

    private func allowButton(title: String, request: @escaping () async -> Void) -> some View {
        Button("Allow") {
            Task {
                await request()
                permissions.refresh(autoPaster: autoPaster)
                focusController.refocusVisibleWindows()
                focusController.refocusVisibleWindows(afterNanoseconds: 300_000_000)
            }
        }
        .buttonStyle(SyrupButtonStyle(height: 24))
        .accessibilityLabel("Allow \(title)")
    }

    // MARK: - Recipe

    private var recipePage: some View {
        VStack(spacing: 0) {
            header(title: "What’s the recipe?")
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 12) {
                if workflow.input == .voice {
                    GridRow {
                        Text("I speak")
                        recipeMenu(
                            label: speakLabel,
                            selection: controls.dictationLocale,
                            choices: controls.dictationLocaleChoices
                        )
                    }
                }
                if let target = OnboardingRecipe.target(of: workflow.kind) {
                    GridRow {
                        Text("and I want")
                        recipeMenu(
                            label: targetLabel(target),
                            selection: targetBinding,
                            choices: (workflow.input == .voice
                                ? [MenuChoice(value: OnboardingTarget.sameLanguage, title: "The same language")]
                                : [])
                                + targetLanguages.enumerated().map { index, language in
                                    MenuChoice(
                                        value: OnboardingTarget.language(language),
                                        title: language,
                                        startsGroup: index == 0 && workflow.input == .voice
                                    )
                                }
                        )
                    }
                }
            }
            .font(.system(size: 14, design: .rounded))
            .padding(.top, 24)

            recipeStatus
                .frame(height: 28)
                .padding(.top, 20)
        }
        .task {
            await applyRecipeDefaults()
        }
    }

    private func recipeMenu<Value: Hashable>(
        label: String,
        selection: Binding<Value>,
        choices: [MenuChoice<Value>]
    ) -> some View {
        Menu {
            MenuChoiceItems(selection: selection, choices: choices)
        } label: {
            HStack {
                Text(label)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .frame(width: 210, height: 28)
            .background(palette.card, in: Capsule())
            .overlay {
                Capsule().strokeBorder(OnboardingPalette.syrup.opacity(0.7), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var recipeStatus: some View {
        if workflow.input == .voice {
            switch assetManager.selectedLocaleAssetState {
            case .installed(let name):
                Label("\(name) is ready", systemImage: "checkmark")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(palette.accent)
            case .downloading(let name, let progress):
                VStack(spacing: 6) {
                    note("Getting \(name) ready")
                    ProgressView(value: progress ?? 0)
                        .progressViewStyle(.linear)
                        .frame(width: 200)
                        .accessibilityLabel("Downloading \(name)")
                }
            case .checking, .unknown:
                note("Checking the language…")
            case .unsupported, .failed:
                note(assetManager.selectedLocaleAssetMessage)
            }
        }
    }

    private var speakLabel: String {
        TranscriberAssetManager.displayName(for: Locale(identifier: workflow.dictationLocaleID))
    }

    private func targetLabel(_ target: OnboardingTarget) -> String {
        switch target {
        case .sameLanguage: "The same language"
        case .language(let language): language
        }
    }

    private var targetLanguages: [String] {
        var languages = ActiveWorkflowBindings.targetLanguages
        if case .language(let current)? = OnboardingRecipe.target(of: workflow.kind), languages.contains(current) == false {
            languages.insert(current, at: 0)
        }
        return languages
    }

    private var targetBinding: Binding<OnboardingTarget> {
        Binding {
            OnboardingRecipe.target(of: workflow.kind) ?? .sameLanguage
        } set: { target in
            settings.updateWorkflow(id: workflow.id) { OnboardingRecipe.apply(target, to: &$0) }
        }
    }

    /// A fresh install starts from this Mac's language rather than the product default.
    private func applyRecipeDefaults() async {
        guard isFreshInstall, didApplyRecipeDefaults == false else {
            assetManager.prepareSelectedLocale(workflow.dictationLocaleID)
            return
        }
        didApplyRecipeDefaults = true
        await state.refreshDictationLocales()
        if let localeID = OnboardingRecipe.preferredLocale(current: .current, supported: assetManager.supportedLocales) {
            controls.dictationLocale.wrappedValue = localeID
        }
        if case .translation(let targetLanguage, _, _) = workflow.kind {
            let target = OnboardingRecipe.defaultTarget(dictationLocaleID: workflow.dictationLocaleID, fallback: targetLanguage)
            settings.updateWorkflow(id: workflow.id) { OnboardingRecipe.apply(target, to: &$0) }
        }
    }

    // MARK: - Flavor

    private var flavorPage: some View {
        VStack(spacing: 0) {
            header(size: 36, title: "Pick a flavor")
            subtitle("Who makes the result? Change it anytime.")
            VStack(spacing: 6) {
                flavorRow(.appleOnDevice, detail: appleDetail)
                flavorRow(.openAICompatible, detail: openAIDetail, detailIsProblem: isConnectionFailure)
                flavorRow(.codexCLI, detail: codexProblem ?? "Uses your ChatGPT plan. A little slower.", detailIsProblem: codexProblem != nil)
            }
            .frame(width: 420)
            .padding(.top, 12)
        }
        .onAppear {
            loadAPIKeyState()
            checkCodexIfNeeded()
        }
        .onChange(of: settings.baseURL) { connectionTest.invalidate() }
        .onChange(of: settings.modelName) { connectionTest.invalidate() }
        .onChange(of: apiKeyInput) { connectionTest.invalidate() }
    }

    private func flavorRow(_ provider: TranslationProvider, detail: String, detailIsProblem: Bool = false) -> some View {
        let isSelected = settings.translationProvider == provider
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                settings.translationProvider = provider
                checkCodexIfNeeded()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "inset.filled.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? OnboardingPalette.syrup : palette.secondaryInk)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.displayName)
                            .fontWeight(.semibold)
                        Text(detail)
                            .font(.system(size: 10.5, design: .rounded))
                            .foregroundStyle(detailIsProblem ? AnyShapeStyle(.red) : AnyShapeStyle(palette.secondaryInk))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])

            if isSelected, provider == .openAICompatible {
                endpointForm
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground(selected: isSelected))
    }

    private var endpointForm: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                formLabel("Endpoint")
                TextField("Endpoint", text: $settings.baseURL)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                formLabel("Model")
                TextField("Model", text: $settings.modelName)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
            }
            GridRow {
                formLabel("API key")
                HStack(spacing: 6) {
                    if hasStoredAPIKey, isReplacingAPIKey == false {
                        Button {
                            isReplacingAPIKey = true
                        } label: {
                            HStack {
                                Text("••••••••••••  Saved")
                                Spacer(minLength: 4)
                                Text("Replace")
                                    .foregroundStyle(palette.accent)
                            }
                            .font(.system(size: 12, design: .rounded))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(palette.field, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Replace the saved API key")
                    } else {
                        SecureField("API key", text: $apiKeyInput, prompt: Text("Stored only on this Mac"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(connectionTest.status == .testing ? "Testing…" : "Test", action: testEndpoint)
                        .buttonStyle(SyrupButtonStyle(height: 24))
                        .disabled(connectionTest.status == .testing)
                }
            }
        }
        .font(.system(size: 12, design: .rounded))
        .padding(.leading, 26)
    }

    private func formLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(palette.secondaryInk)
    }

    private var appleDetail: String {
        let message = AppleOnDeviceTransformer.availabilityMessage()
        return message == "Ready" ? "Private and offline. Needs Apple Intelligence." : message
    }

    private var openAIDetail: String {
        switch connectionTest.status {
        case .success:
            "Connection OK."
        case .failure(let message):
            message
        case .saved(let message):
            message
        case .idle, .testing:
            "Your API key or local server."
        }
    }

    private var isConnectionFailure: Bool {
        if case .failure = connectionTest.status { return true }
        return false
    }

    private func loadAPIKeyState() {
        Task {
            hasStoredAPIKey = await Task.detached(priority: .userInitiated) { [keychainStore] in
                (try? keychainStore.load())??.isEmpty == false
            }.value
        }
    }

    /// True when there is nothing to save or the key saved. A failure stays on the page with its message.
    private func saveTypedAPIKey() async -> Bool {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty == false, settings.translationProvider == .openAICompatible else { return true }
        do {
            try await Task.detached(priority: .userInitiated) { [keychainStore] in
                try keychainStore.save(key)
            }.value
            apiKeyInput = ""
            hasStoredAPIKey = true
            isReplacingAPIKey = false
            return true
        } catch {
            connectionTest.show(.failure(userMessage(for: error)))
            return false
        }
    }

    private func testEndpoint() {
        let baseURL = settings.baseURL
        let modelName = settings.modelName
        Task {
            guard await saveTypedAPIKey() else { return }
            let request = connectionTest.begin()
            await connectionTest.run(request) {
                let configuration = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
                    baseURLString: baseURL,
                    modelName: modelName,
                    keychainStore: keychainStore
                )
                try await endpointTester.testConnection(configuration: configuration)
            }
        }
    }

    private func checkCodexIfNeeded() {
        guard settings.translationProvider == .codexCLI else {
            codexProblem = nil
            return
        }
        let path = settings.codexPath
        let model = settings.codexModel
        Task {
            let status = await codexStatusChecker.status(configuredPath: path, modelName: model)
            codexProblem = status.kind == .ready ? nil : status.message
        }
    }

    // MARK: - Taste

    private var tastePage: some View {
        VStack(spacing: 0) {
            header(mood: tasteMood, title: tasteResultSucceeded ? "Sweet! You’re all set" : "Have a taste")
            tasteSubtitle
                .padding(.top, 4)

            tasteBubble
                .frame(width: 360, height: 84)
                .padding(.top, 20)

            Group {
                if tasteResultSucceeded == false {
                    Button("Change shortcut…") {
                        isShowingShortcutPopover = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(palette.accent)
                    .popover(isPresented: $isShowingShortcutPopover) {
                        KeyboardShortcuts.Recorder("Dictate", name: .dictate) { _ in
                            state.refreshWorkflowHotkeys()
                        }
                        .padding(12)
                    }
                }
            }
            .frame(height: 16)
            .padding(.top, 12)
        }
    }

    private var tasteMood: SyrupDrop.Mood {
        if tasteResultSucceeded { return .happy }
        return state.pipelineState == .recording ? .listening : .smiling
    }

    @ViewBuilder
    private var tasteSubtitle: some View {
        if tasteResultSucceeded {
            Text("I live in your menu bar. Use the same keys anywhere you type.")
                .foregroundStyle(palette.secondaryInk)
        } else if state.pipelineState == .recording {
            Text("I’m listening…")
                .foregroundStyle(palette.secondaryInk)
        } else if state.pipelineState == .transcribing || state.pipelineState == .translating {
            Text("Pouring…")
                .foregroundStyle(palette.secondaryInk)
        } else {
            HStack(spacing: 4) {
                Text(tasteInstruction.before)
                if let shortcut = KeyboardShortcuts.getShortcut(for: .dictate) {
                    Text(shortcut.description)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .background(palette.card, in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line)
                        }
                }
                Text(tasteInstruction.after)
            }
            .foregroundStyle(palette.secondaryInk)
        }
    }

    private var tasteInstruction: (before: String, after: String) {
        guard KeyboardShortcuts.getShortcut(for: .dictate) != nil else {
            return ("Set a shortcut, then say anything.", "")
        }
        let headline = HomeStatus.headline(phase: .idle, input: workflow.input, mode: settings.hotkeyMode, hasShortcut: true)
        return (headline.before, headline.after.isEmpty ? "" : "and say anything.")
    }

    @ViewBuilder
    private var tasteBubble: some View {
        ZStack {
            rowBackground()
            if let record = tasteResult, tasteResultSucceeded {
                VStack(alignment: .leading, spacing: 6) {
                    tasteLine(label: "You said", text: record.transcript, emphasized: false)
                    tasteLine(label: "Syrup poured", text: record.output ?? record.transcript, emphasized: true)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            } else if case .failed(let message)? = tasteResult?.outcome {
                Text(message)
                    .foregroundStyle(palette.secondaryInk)
                    .padding(.horizontal, 16)
            } else if case .error(let message) = state.pipelineState {
                Text(message)
                    .foregroundStyle(palette.secondaryInk)
                    .padding(.horizontal, 16)
            } else if state.pipelineState == .idle {
                Text("Your first result lands here.")
                    .foregroundStyle(palette.secondaryInk)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func tasteLine(label: String, text: String, emphasized: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(palette.secondaryInk)
            Text(text)
                .fontWeight(emphasized ? .semibold : .regular)
                .lineLimit(1)
        }
    }

    /// The newest result since this page opened.
    private var tasteResult: DictationRecord? {
        state.history.records.first { $0.finishedAt >= tasteStartedAt }
    }

    private var tasteResultSucceeded: Bool {
        tasteResult?.outcome == .success
    }

    private func showSprinkles() {
        showsSprinkles = true
        Task {
            try? await Task.sleep(for: .seconds(3.2))
            showsSprinkles = false
        }
    }
}
