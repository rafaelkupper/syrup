import KeyboardShortcuts
import SwiftUI

struct HomeSettingsPane: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var state: AppState
    let speechModels: SpeechModelCatalog
    @Bindable var navigation: SettingsNavigation
    let permissions: PermissionStatusModel
    let onPasteEnabled: () -> Void
    @State private var providerSetupMessage: String?
    /// Results that finished after this are highlighted until they have been seen.
    @State private var highlightAfter = Date.distantFuture

    var body: some View {
        Form {
            Section {
                WorkflowSentence(bindings: bindings, onPasteEnabled: onPasteEnabled)
                    .font(.title2)
                    .padding(.vertical, 4)
            } header: {
                statusHeader
            }

            if attentionItems.isEmpty == false {
                attentionSection
            }
            if state.settings.keepsUsageStats {
                HomeStatsSection(stats: state.usageStats.stats)
            }
            recentSection
        }
        .formStyle(.grouped)
        .task(id: workflow.dictationLocaleID) {
            guard workflow.input == .voice else { return }
            state.transcriberAssetManager.prepareSelectedLocale(workflow.dictationLocaleID)
        }
        .task(id: "\(workflow.id)\(provider?.rawValue ?? "")") {
            providerSetupMessage = await providerProblem()
        }
        .onAppear(perform: markRecentSeen)
        .onChange(of: state.history.records.first?.id) { markRecentSeen() }
    }

    // MARK: - Status

    private var statusHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 34, height: 34)
                .background(statusColor.opacity(0.15), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                headlineView
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 12)

            if phase == .paused {
                Button {
                    state.isHotkeyPaused = false
                } label: {
                    Label("Resume", systemImage: "mic")
                }
                .buttonStyle(.borderedProminent)
            } else if phase == .idle {
                Button {
                    state.isHotkeyPaused = true
                } label: {
                    Label("Pause Shortcuts", systemImage: "pause")
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var headlineView: some View {
        HStack(spacing: 7) {
            Text(headline.before)
            if headline.showsShortcut, let shortcut = dictateShortcut {
                ShortcutChip(text: shortcut.description)
                    .font(.title3.weight(.medium))
            }
            if headline.after.isEmpty == false {
                Text(headline.after)
            }
            if dictateShortcut == nil, phase == .idle {
                Button("Set Shortcut…") {
                    navigation.selectedTab = .dictation
                }
                .font(.body)
            }
        }
    }

    private var statusDetail: String {
        switch phase {
        case .paused:
            return "Dictate, Revise, and Fn do nothing until you resume."
        case .idle:
            let warnings = attentionItems.filter { $0.severity == .warning }.count
            if warnings > 0 {
                return warnings == 1
                    ? "1 thing needs your attention, but you can still dictate."
                    : "\(warnings) things need your attention, but you can still dictate."
            }
            if state.settings.dictateWithFnKey {
                return state.settings.hotkeyMode == .hold
                    ? "Ready. Fn works too: hold it, or double-tap to start."
                    : "Ready. Fn works too: double-tap to start."
            }
            return "Ready."
        case .recording, .transcribing, .translating:
            return "Results land on the clipboard when they're ready."
        case .error:
            return "Try again, or check Recent below."
        }
    }

    private var statusSymbol: String {
        switch phase {
        case .paused: "pause"
        case .recording: "waveform"
        case .error: "exclamationmark.triangle"
        case .transcribing, .translating: "ellipsis"
        case .idle: hasWarnings ? "exclamationmark.triangle" : "mic"
        }
    }

    private var statusColor: Color {
        switch phase {
        case .paused: .secondary
        case .recording, .error: .red
        case .transcribing, .translating: .accentColor
        case .idle: hasWarnings ? .orange : .green
        }
    }

    private var hasWarnings: Bool {
        attentionItems.contains { $0.severity == .warning }
    }

    // MARK: - Needs attention

    private var attentionSection: some View {
        Section {
            ForEach(attentionItems) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(item.severity == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    Text(item.message)
                    Spacer()
                    attentionAction(item.action)
                }
            }
        }
    }

    @ViewBuilder
    private func attentionAction(_ action: HomeStatus.AttentionItem.Action) -> some View {
        switch action {
        case .open(let tab):
            Button("Show…") {
                navigation.selectedTab = tab
            }
        case .openActiveWorkflow:
            Button("Show…") {
                navigation.openWorkflow(workflow.id)
            }
        case .downloadSpeechModel:
            Button("Download (\(workflow.speechEngine.downloadSize ?? ""))") {
                speechModels.manager(for: workflow.speechEngine)?.download()
            }
        case .none:
            ProgressView()
                .controlSize(.small)
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        Section {
            if state.history.records.isEmpty {
                emptyRecent
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ForEach(state.history.records) { record in
                    recentRow(record, now: context.date)
                }
            }
            if let message = state.history.persistenceError {
                Text(message)
                    .foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Recent")
                Spacer()
                if state.history.records.isEmpty == false {
                    Button("Clear History…", action: clearHistory)
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        } footer: {
            HStack(spacing: 4) {
                Text(state.settings.persistHistory ? "History is kept on this Mac." : "History stays in memory until Syrup quits.")
                Button(state.settings.persistHistory ? "Change…" : "Keep it across restarts…") {
                    navigation.selectedTab = .privacy
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private var emptyRecent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let shortcut = dictateShortcut, workflow.input == .voice {
                HStack(spacing: 4) {
                    Text(state.settings.hotkeyMode == .hold ? "Try it now. Hold" : "Try it now. Press")
                    ShortcutChip(text: shortcut.description)
                    Text("and say something.")
                }
                Text("Your results appear here, with a button to copy them again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Your results appear here, with a button to copy them again.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func recentRow(_ record: DictationRecord, now: Date) -> some View {
        let isFresh = record.finishedAt > highlightAfter
        return HStack(alignment: .top, spacing: 10) {
            if case .failed = record.outcome {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
            } else {
                WorkflowTile(style: WorkflowStyle(record), size: 20)
            }

            VStack(alignment: .leading, spacing: 2) {
                recentTitle(record)
                    .fontWeight(isFresh ? .medium : .regular)
                Text(Self.recentDetail(record, now: now))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)

            recentActions(record)
        }
        .padding(.vertical, 2)
        .listRowBackground(isFresh ? Color.accentColor.opacity(0.1) : nil)
    }

    @ViewBuilder
    private func recentTitle(_ record: DictationRecord) -> some View {
        if case .failed(let message) = record.outcome {
            Text(message)
                .lineLimit(2)
        } else {
            Text(record.output ?? record.transcript)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func recentActions(_ record: DictationRecord) -> some View {
        if case .failed = record.outcome {
            HStack(spacing: 8) {
                if record.canUseTranscriptFallback {
                    Button("Copy Transcript") {
                        state.copyTranscriptFallback(recordID: record.id)
                    }
                }
                if record.canRetry {
                    Menu("Retry") {
                        if record.canRetryWithOriginalProvider {
                            Button("Retry \(record.transformation.displayName)") {
                                state.retryTranslation(recordID: record.id)
                            }
                        }
                        ForEach(TranslationProvider.allCases.filter { $0 != record.provider }) { provider in
                            Button("Use \(provider.displayName)") {
                                state.retryTranslation(recordID: record.id, using: provider)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            .controlSize(.small)
            .disabled(state.pipelineState.isActive)
        } else if record.canCopyFromHistory {
            Button {
                state.copyHistoryRecord(recordID: record.id)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy result")
            .accessibilityLabel("Copy result")
            .disabled(state.pipelineState.isActive)
        }
    }

    static func recentDetail(_ record: DictationRecord, now: Date = .now) -> String {
        var parts = [
            record.transformation.displayName,
            record.finishedAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
        ]
        if case .failed = record.outcome, record.canUseTranscriptFallback {
            parts.append("your transcript was kept")
        } else if let provider = record.provider {
            parts.append(provider.displayName)
        } else if record.outcome == .success {
            parts.append("on this Mac")
        }
        if let duration = record.duration {
            parts.append(HomeStatus.durationLabel(duration))
        }
        return parts.joined(separator: " · ")
    }

    private func markRecentSeen() {
        highlightAfter = navigation.recentSeenAt
        navigation.recentSeenAt = .now
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if reduceMotion {
                highlightAfter = .distantFuture
            } else {
                withAnimation(.easeOut(duration: 1.2)) { highlightAfter = .distantFuture }
            }
        }
    }

    private func clearHistory() {
        let count = state.history.records.count
        guard confirmDestructiveAction(
            message: count == 1 ? "Clear 1 result from History?" : "Clear \(count) results from History?",
            detail: "This can't be undone.",
            confirmTitle: "Clear History"
        ) else { return }
        Task { await state.history.clear() }
    }

    // MARK: - State

    private var bindings: WorkflowBindings {
        WorkflowBindings(
            settings: state.settings,
            workflowID: workflow.id,
            assetManager: state.transcriberAssetManager,
            speechModels: speechModels
        )
    }

    private var workflow: Workflow { state.settings.activeWorkflow }

    private var provider: TranslationProvider? {
        workflow.kind.isTranscribeOnly ? nil : workflow.translationProvider ?? state.settings.translationProvider
    }

    private var dictateShortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: .dictate)
    }

    private var phase: HomeStatus.Phase {
        if state.isHotkeyPaused, state.pipelineState == .idle { return .paused }
        return switch state.pipelineState {
        case .idle: .idle
        case .recording: .recording
        case .transcribing: .transcribing
        case .translating: .translating
        case .error(let message): .error(message)
        }
    }

    private var headline: HomeStatus.Headline {
        HomeStatus.headline(
            phase: phase,
            input: workflow.input,
            mode: state.settings.hotkeyMode,
            hasShortcut: dictateShortcut != nil,
            isFnLatched: state.isFnRecordingLatched
        )
    }

    private var attentionItems: [HomeStatus.AttentionItem] {
        HomeStatus.attentionItems(HomeStatus.Inputs(
            microphone: permissions.microphone,
            speech: permissions.speech,
            accessibility: permissions.accessibility,
            autoPasteEnabled: state.settings.autoPasteEnabled,
            usesVoice: workflow.input == .voice,
            localeState: state.transcriberAssetManager.selectedLocaleAssetState,
            localeMessage: state.transcriberAssetManager.selectedLocaleAssetMessage,
            speechModelName: speechModels.manager(for: workflow.speechEngine) == nil ? nil : workflow.speechEngine.displayName,
            speechModelState: speechModels.manager(for: workflow.speechEngine)?.state ?? .notDownloaded,
            providerSetupMessage: providerSetupMessage,
            glossarySuggestionCount: state.settings.glossaryProposals.proposals.count
        ))
    }

    /// Uses the same checks a run uses, so Home and the run agree.
    /// Runs when the window opens or the workflow or provider changes, not on every keystroke in Models.
    private func providerProblem() async -> String? {
        switch provider {
        case .openAICompatible:
            do {
                _ = try await OpenAICompatibleSettingsConfigurationResolver.configuration(
                    baseURLString: state.settings.baseURL,
                    modelName: state.settings.modelName,
                    keychainStore: state.keychainStore
                )
                return nil
            } catch {
                return "Finish setting up your OpenAI-compatible provider"
            }
        case .appleOnDevice:
            let message = AppleOnDeviceTransformer.availabilityMessage()
            return message == "Ready" ? nil : message
        case .codexCLI, nil:
            return nil
        }
    }
}
