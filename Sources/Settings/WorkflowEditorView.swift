import AppKit
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowEditorView: View {
    let workflowID: UUID
    @Bindable var settings: AppSettings
    @Bindable var assetManager: TranscriberAssetManager
    let speechModels: SpeechModelCatalog
    let onPasteEnabled: () -> Void
    let shortcutChangeHandler: () -> Void

    var body: some View {
        Form {
            Section {
                WorkflowSentence(bindings: bindings, showsProvider: true, onPasteEnabled: onPasteEnabled)
                    .font(.title3)
                    .padding(.vertical, 2)
            } header: {
                header
            }
            inputSection
            outputSection
            if workflow.input == .voice { correctionsSection }
            triggersSection
        }
        .formStyle(.grouped)
        .onAppear {
            if workflow.input == .voice {
                assetManager.prepareSelectedLocale(workflow.dictationLocaleID)
                speechModels.manager(for: workflow.speechEngine)?.loadIfDownloaded()
            }
        }
    }

    private var bindings: WorkflowBindings {
        WorkflowBindings(settings: settings, workflowID: workflowID, assetManager: assetManager, speechModels: speechModels)
    }

    private var workflow: Workflow { bindings.workflow }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            WorkflowTile(style: WorkflowStyle(workflow.kind), size: 38)
            VStack(alignment: .leading, spacing: 1) {
                TextField("Name", text: Binding { workflow.name } set: { name in bindings.update { $0.name = name } })
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityLabel("Workflow name")
                Text(workflow.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if bindings.isActive {
                StatusPill(text: "Active", tone: .ok)
                    .help("Dictate runs this workflow unless an app is set to another one")
            } else {
                Button("Make Active") {
                    settings.setActiveWorkflowID(workflow.id)
                    shortcutChangeHandler()
                }
            }
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }

    // MARK: - Input

    private var inputSection: some View {
        Section("Input") {
            if workflow.kind.isTranscribeOnly == false {
                LabeledContent("Source") {
                    Picker("Source", selection: bindings.input) {
                        Text("Voice").tag(WorkflowInput.voice)
                        Text("Selected text").tag(WorkflowInput.selection)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
            }

            switch workflow.input {
            case .voice:
                LabeledContent {
                    Picker("Dictation language", selection: bindings.dictationLocale) {
                        bindings.dictationLocaleOptions
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Dictation language")
                    Text(assetManager.selectedLocaleAssetMessage)
                }
                if let progress = assetManager.selectedLocaleProgress {
                    ProgressView(value: progress)
                }

                LabeledContent {
                    Picker("Speech model", selection: bindings.speechEngine) {
                        ForEach(bindings.availableSpeechEngines) { engine in
                            Text(engine.displayName).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("Speech model")
                    Text(speechModelCaption)
                }
                if let model = speechModels.manager(for: workflow.speechEngine), model.state != .ready, model.state != .downloaded {
                    LabeledContent {
                        SpeechModelControls(model: model)
                    } label: {
                        Text("Until \(model.engine.displayName) is ready, this workflow uses Apple speech")
                            .foregroundStyle(.secondary)
                    }
                }

                if workflow.kind.isTranscribeOnly == false {
                    LabeledContent {
                        Toggle("Include selected text", isOn: bindings.includeSelectionContext)
                            .labelsHidden()
                    } label: {
                        Text("Include selected text")
                        Text("So you can say “reply to this”. It goes to this workflow's AI provider.")
                    }
                }
            case .selection:
                LabeledContent {
                    EmptyView()
                } label: {
                    Text("Selected text")
                    Text("Read with Accessibility when you press the shortcut, up to 20,000 characters. Never saved.")
                }
            }
        }
    }

    private var speechModelCaption: String {
        let engine = workflow.speechEngine
        if speechModels.manager(for: .parakeetUltra)?.state == .unsupported {
            return "\(engine.tagline). Downloads need a Mac with Apple silicon."
        }
        if bindings.availableSpeechEngines == [.apple] {
            return "\(engine.tagline). No download supports this language."
        }
        if let state = speechModels.manager(for: engine)?.state, state == .ready || state == .downloaded {
            return engine.isStreaming
                ? "\(engine.displayName) is ready and shows its own live words."
                : "\(engine.displayName) is ready. Apple shows the live words."
        }
        return engine.tagline
    }

    // MARK: - Output

    private var outputSection: some View {
        Section {
            LabeledContent {
                Picker("Action", selection: bindings.kind) {
                    ForEach(WorkflowBindings.KindOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                Text("Action")
                if workflow.kind.isTranscribeOnly {
                    Text("No AI provider. Nothing leaves this Mac.")
                }
            }

            switch workflow.kind {
            case .translation(_, let tone, _):
                LabeledContent("Translate to") {
                    TextField("Translate to", text: bindings.targetLanguage)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading)
                        .frame(width: 200)
                }
                LabeledContent("Tone") {
                    Picker("Tone", selection: bindings.tonePreset) {
                        ForEach(TonePreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if tone == .custom {
                    LabeledContent("Custom tone") {
                        TextField("Custom tone", text: bindings.customToneText)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                    }
                }
                if workflow.input == .voice {
                    SpokenEditsRows(settings: settings, provider: bindings.effectiveProvider)
                }
            case .custom:
                VStack(alignment: .leading, spacing: 6) {
                    Text("Instruction")
                    TextEditor(text: bindings.customInstruction)
                        .font(.body)
                        .frame(minHeight: 72)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        .accessibilityLabel("Instruction")
                }
                LabeledContent {
                    Toggle("Output only the result", isOn: bindings.outputContract)
                        .labelsHidden()
                } label: {
                    Text("Output only the result")
                    Text("Adds: “\(PromptBuilder.outputContract)”")
                }
            case .transcribeOnly:
                LabeledContent {
                    Toggle("Clean up fillers and spoken formatting", isOn: bindings.cleanup)
                        .labelsHidden()
                } label: {
                    Text("Clean up fillers and spoken formatting")
                    Text("English and Portuguese, with rules on this Mac")
                }
                LabeledContent {
                    Toggle("Replace spoken symbols", isOn: bindings.spokenSymbols)
                        .labelsHidden()
                } label: {
                    Text("Replace spoken symbols")
                    Text("Replaces words like “hashtag” and “arroba” even in ordinary sentences")
                }
                DisclosureGroup("Words it replaces") {
                    Text("English: hashtag, hash sign, at sign, underscore, hyphen, slash, comma, semicolon, colon. Portuguese: hashtag, jogo da velha, arroba, sinal de arroba, sublinhado, underscore, hífen, barra, vírgula, ponto e vírgula, dois pontos.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }

            if workflow.kind.isTranscribeOnly == false {
                LabeledContent {
                    Picker("AI provider", selection: bindings.providerOverride) {
                        bindings.providerOptions
                    }
                    .labelsHidden()
                    .fixedSize()
                } label: {
                    Text("AI provider")
                    Text(providerCaption)
                }
            }
        } header: {
            Text("Output")
        } footer: {
            if case .translation = workflow.kind, workflow.input == .voice {
                Text("Self-corrections and formatting commands are shared by every Translate workflow whose provider can do them.")
                    .font(.caption)
            }
        }
    }

    private var providerCaption: String {
        if workflow.input == .selection || workflow.includeSelectionContext,
           bindings.effectiveProvider != .appleOnDevice {
            return "Apple On-Device keeps selected text on this Mac"
        }
        return bindings.effectiveProvider.latencyHint
    }

    // MARK: - Corrections

    private var correctionsSection: some View {
        Section {
            if workflow.corrections.isEmpty == false {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("Heard")
                        Color.clear.frame(width: 12, height: 1)
                        Text("Replace with")
                        Color.clear.frame(width: 20, height: 1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    ForEach(workflow.corrections.indices, id: \.self) { index in
                        GridRow {
                            TextField("Heard", text: correctionBinding(index, \.heard))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                            TextField("Replace with", text: correctionBinding(index, \.replacement))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                            Button {
                                bindings.update { $0.corrections.remove(at: index) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove correction")
                            .accessibilityLabel("Remove correction")
                        }
                    }
                }
            }
            Button(workflow.corrections.isEmpty ? "Add a Correction for a Word It Keeps Mishearing" : "Add Correction") {
                bindings.update { $0.corrections.append(Correction(heard: "", replacement: "")) }
            }
            .buttonStyle(.link)
        } header: {
            HStack {
                Text("Corrections")
                Spacer()
                Text("Fixes a word before anything else runs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func correctionBinding(_ index: Int, _ keyPath: WritableKeyPath<Correction, String>) -> Binding<String> {
        Binding {
            workflow.corrections.indices.contains(index) ? workflow.corrections[index][keyPath: keyPath] : ""
        } set: { value in
            bindings.update {
                guard $0.corrections.indices.contains(index) else { return }
                $0.corrections[index][keyPath: keyPath] = value
            }
        }
    }

    // MARK: - When it runs

    private var routedBundleIDs: [String] {
        settings.workflowList.appRouting.keys.filter { settings.workflowList.appRouting[$0] == workflow.id }.sorted()
    }

    private var triggersSection: some View {
        Section("When it runs") {
            LabeledContent {
                KeyboardShortcuts.Recorder(for: .dictateWorkflow(workflow.id)) { _ in
                    shortcutChangeHandler()
                }
            } label: {
                Text("Its own shortcut")
                Text("Runs this workflow from any app")
            }

            LabeledContent {
                Button("Add App…", action: addApp)
            } label: {
                Text("In these apps")
                Text("Dictate uses this workflow while one of them is in front")
            }
            ForEach(routedBundleIDs, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    AppIcon(bundleID: bundleID, size: 20)
                    Text(AppInfoCache.name(for: bundleID))
                    Spacer()
                    Button {
                        settings.workflowList.routeApplication(bundleID, to: nil)
                        shortcutChangeHandler()
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(AppInfoCache.name(for: bundleID))")
                    .accessibilityLabel("Remove \(AppInfoCache.name(for: bundleID))")
                }
                .padding(.leading, 12)
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(filePath: "/Applications")
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            settings.workflowList.routeApplication(bundleID, to: workflow.id)
            shortcutChangeHandler()
        }
    }
}
