import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct GlossaryExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    static let writableContentTypes: [UTType] = [.json]

    let glossary: GlossaryList

    init(glossary: GlossaryList) {
        self.glossary = glossary
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        glossary = try JSONDecoder().decode(GlossaryList.self, from: data)
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(glossary)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try encodedData())
    }
}

struct GlossarySettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var navigation: SettingsNavigation
    let recordingArchive: (any RecordingArchiving)?
    @Bindable var whisperModelManager: WhisperModelManager
    let learningCoordinator: GlossaryLearningCoordinator?
    @Environment(MishearingSuggestionModel.self) private var suggestions
    @State private var pendingRecordingCount = 0
    @State private var recordingDeletionFailed = false
    @State private var isConfirmingModelRemoval = false
    @State private var selectedTermID: UUID?
    @State private var termDrafts: [UUID: String] = [:]
    @State private var mishearingDrafts: [UUID: String] = [:]
    @State private var newMishearingsDraft = ""
    @State private var isExportingGlossary = false
    @State private var searchText = ""
    @FocusState private var isNewTermFocused: Bool

    var body: some View {
        Form {
            if settings.glossaryList.terms.isEmpty {
                emptyStateSection
            } else {
                termsSection
                MishearingCheckSection(
                    suggestions: suggestions,
                    settings: settings,
                    navigation: navigation,
                    onAccept: acceptSuggestion
                )
            }

            if settings.glossaryProposals.proposals.isEmpty == false {
                suggestionsSection
            }

            learningSection
            builtInVocabularySection
        }
        .formStyle(.grouped)
        .fileExporter(
            isPresented: $isExportingGlossary,
            document: GlossaryExportDocument(glossary: settings.glossaryList),
            contentType: .json,
            defaultFilename: "syrup-glossary",
            onCompletion: { _ in }
        )
        .onAppear {
            synchronizeDrafts()
        }
        .onChange(of: settings.glossaryList) { _, _ in
            synchronizeDrafts()
        }
        .onChange(of: settings.glossaryLearningEnabled) { _, isEnabled in
            Task {
                await applyGlossaryLearningRetentionChange(
                    isEnabled: isEnabled,
                    settings: settings,
                    recordingArchive: recordingArchive,
                    revertsSettingOnFailure: true
                )
            }
        }
        .confirmationDialog(
            "Delete the comparison model too?",
            isPresented: $isConfirmingModelRemoval,
            titleVisibility: .visible
        ) {
            Button("Delete Model (626 MB)", role: .destructive) {
                whisperModelManager.removeModel()
            }
            Button("Keep Model", role: .cancel) {}
        } message: {
            Text("Waiting recordings are deleted either way. The model downloads again if you turn learning back on.")
        }
        .task {
            guard let recordingArchive else { return }
            for await count in await recordingArchive.pendingEntryCounts() {
                pendingRecordingCount = count
            }
        }
        .task(id: navigation.glossaryFocusRequest) {
            await Task.yield()
            isNewTermFocused = true
        }
    }

    private var emptyStateSection: some View {
        Section {
            VStack(spacing: 6) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                Text("Teach Syrup your words")
                    .font(.headline)
                Text("Add names, brands, and technical terms that dictation gets wrong, like “Kubernetes” or a coworker’s name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Button("Add Your First Term") {
                    isNewTermFocused = true
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)

            addTermRow
        }
    }

    private var termsSection: some View {
        Section {
            Table(filteredTerms, selection: $selectedTermID) {
                TableColumn("Spelling") { term in
                    VStack(alignment: .leading) {
                        TextField("Term", text: termBinding(for: term), prompt: Text("Term"))
                            .labelsHidden()
                        if let message = validationMessage(for: term.id) {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                TableColumn("Sounds like") { term in
                    HStack(spacing: 6) {
                        TextField(
                            "Sounds like",
                            text: mishearingsBinding(for: term),
                            prompt: Text("e.g. cuber netties")
                        )
                        .labelsHidden()
                        MishearingTermStatus(suggestions: suggestions, termID: term.id)
                    }
                }

                TableColumn("") { term in
                    MishearingCheckButton(suggestions: suggestions, term: term)
                }
                .width(20)

                TableColumn("") { term in
                    Button {
                        deleteTerm(id: term.id)
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Delete “\(term.term)”")
                }
                .width(24)
            }
            .frame(height: min(CGFloat(filteredTerms.count) * 28 + 32, 300))

            addTermRow
        } header: {
            HStack(spacing: 8) {
                Text("Terms")
                Text(termCountCaption)
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
                TextField("Search", text: $searchText, prompt: Text("Search"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .accessibilityLabel("Search terms")
                Menu {
                    Button("Export Glossary…") {
                        isExportingGlossary = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("More")
            }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Exact spellings go to speech recognition and to your AI provider with each run. To fix one word in one workflow, use that workflow's Corrections.")

                if settings.glossaryList.terms.count > GlossaryList.maximumUsedTerms {
                    Label(
                        "Only the first \(GlossaryList.maximumUsedTerms) terms are sent — trim the list.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    private var addTermRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("New term", text: $navigation.glossaryDraftTerm, prompt: Text("New term"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .focused($isNewTermFocused)
                    .onSubmit(addTerm)

                TextField(
                    "Sounds like",
                    text: $newMishearingsDraft,
                    prompt: Text("Sounds like, separated by commas (optional)")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTerm)

                Button("Add", systemImage: "plus", action: addTerm)
                    .disabled(canAddTerm == false)
            }

            if let message = newTermValidationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var builtInVocabularySection: some View {
        Section("Built-in vocabulary") {
            LabeledContent {
                Toggle("Common tech terms", isOn: $settings.includeCommonTechTerms)
                    .labelsHidden()
            } label: {
                Text("Common tech terms")
                Text("Words like “deploy” and “pull request”. Your terms come first.")
            }
        }
    }

    private var learningSection: some View {
        Section {
            LabeledContent {
                Toggle(
                    "Suggest terms from my recordings",
                    isOn: learningToggleBinding
                )
                .labelsHidden()
            } label: {
                Text("Suggest terms from my recordings")
                Text("Keeps audio on this Mac until it's compared, then deletes it")
            }

            if settings.glossaryLearningEnabled {
                recognitionModelRow
                pendingRecordingsRow
            } else if whisperModelManager.state == .ready {
                // Learning is off but the 626 MB model is still on disk —
                // keep the removal path reachable without re-enabling.
                recognitionModelRow
            }

        } header: {
            Text("Learning")
        } footer: {
            DisclosureGroup("What is sent, and where?") {
                Text(glossaryLearningPrivacyDescription)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    private var suggestionsSection: some View {
        Section("Suggested from your recordings") {
            ForEach(settings.glossaryProposals.proposals) { proposal in
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("Add") {
                            addProposalToGlossary(proposal)
                        }
                        .accessibilityLabel("Add \(proposal.term) to glossary")

                        Button("Dismiss") {
                            settings.dismissGlossaryProposal(id: proposal.id)
                        }
                        .accessibilityLabel("Dismiss \(proposal.term) suggestion")
                    }
                } label: {
                    Text(proposal.term)
                    Text("Heard as “\(proposal.mishearings.joined(separator: ", "))”")
                }
            }
        }
    }

    @ViewBuilder
    private var recognitionModelRow: some View {
        LabeledContent("Comparison model") {
            switch whisperModelManager.state {
            case .notDownloaded:
                HStack(spacing: 8) {
                    Text("Not downloaded")
                        .foregroundStyle(.secondary)
                    Button("Download (626 MB)") {
                        downloadRecognitionModel()
                    }
                }
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(width: 180)
                    .accessibilityLabel("Downloading comparison model")
                    .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
            case .ready:
                HStack(spacing: 8) {
                    Text("Ready (626 MB)")
                        .foregroundStyle(.secondary)
                    Button("Delete", role: .destructive) {
                        whisperModelManager.removeModel()
                    }
                    .disabled(isAnalyzing)
                    .help("When learning is enabled, a new pending recording can download the model again.")
                }
            case .failed(let message):
                HStack(spacing: 8) {
                    Text(message)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        downloadRecognitionModel()
                    }
                    Button("Delete", role: .destructive) {
                        whisperModelManager.removeModel()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pendingRecordingsRow: some View {
        LabeledContent("Waiting to be compared") {
            HStack(spacing: 8) {
                if isAnalyzing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Comparing…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(pendingRecordingCount == 1 ? "1 recording" : "\(pendingRecordingCount) recordings")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Button("Compare Now") {
                    runAnalysisPass()
                }
                .disabled(
                    learningCoordinator == nil
                        || isAnalyzing
                        || pendingRecordingCount == 0
                        || whisperModelManager.state != .ready
                )
                .help("Runs the idle-time analysis immediately instead of waiting for the scheduler.")

                Button("Delete All") {
                    clearPendingRecordings()
                }
                .disabled(isAnalyzing || pendingRecordingCount == 0)
            }
        }
        if recordingDeletionFailed {
            Text("Some recordings could not be deleted. Syrup tries again at the next cleanup.")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - System voice check

    /// Everyday words can make the AI rewrite ordinary sentences, so they ask first.
    private func acceptSuggestion(_ form: String, for term: GlossaryTerm) {
        if case .results(let result) = suggestions.state(for: term.id), result.isEveryday(form),
           confirmEverydayHint(form: form, term: term.term) == false {
            return
        }
        guard suggestions.accept(form, for: term.id),
              let updated = settings.glossaryList.terms.first(where: { $0.id == term.id }) else { return }
        // The field shows its draft, so show the added hint there too.
        mishearingDrafts[term.id] = updated.mishearings.joined(separator: ", ")
    }

    private var isAnalyzing: Bool {
        learningCoordinator?.isRunning == true
    }

    /// Turning learning off always deletes pending recordings (handled by the
    /// onChange above); the model is a separate 626 MB decision, so ask.
    private var learningToggleBinding: Binding<Bool> {
        Binding {
            settings.glossaryLearningEnabled
        } set: { isEnabled in
            settings.glossaryLearningEnabled = isEnabled
            if isEnabled == false, whisperModelManager.state == .ready {
                isConfirmingModelRemoval = true
            }
        }
    }

    private func downloadRecognitionModel() {
        Task {
            await whisperModelManager.ensureModel()
        }
    }

    private func runAnalysisPass() {
        Task {
            await learningCoordinator?.runPass()
        }
    }

    private func clearPendingRecordings() {
        Task {
            do {
                try await recordingArchive?.deleteAll()
                recordingDeletionFailed = false
            } catch {
                recordingDeletionFailed = true
            }
        }
    }

    private func addProposalToGlossary(_ proposal: GlossaryProposal) {
        settings.addGlossaryTerm(GlossaryTerm(
            term: proposal.term,
            mishearings: proposal.mishearings
        ))
        settings.removeGlossaryProposal(id: proposal.id)
    }

    private var glossaryLearningPrivacyDescription: String {
        let retention = "When enabled, Syrup keeps each dictation's audio on this Mac (at most 50 recordings or 7 days) until it is analyzed during idle time, then deletes it."
        let suggestions = "Suggestions appear here for your approval."

        if settings.translationProvider == .appleOnDevice {
            return "\(retention) Analysis re-transcribes the audio on-device and compares the two transcript versions using your configured AI provider (\(settings.translationProvider.displayName) — fully on-device) to spot misheard terms. Nothing leaves your Mac. \(suggestions)"
        }

        return "\(retention) Analysis re-transcribes the audio on-device and may send the two transcript versions to your configured AI provider (\(settings.translationProvider.displayName)) to spot misheard terms. Audio, your glossary, and other content stay on your Mac. \(suggestions)"
    }

    private var filteredTerms: [GlossaryTerm] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.isEmpty == false else { return settings.glossaryList.terms }
        return settings.glossaryList.terms.filter { term in
            term.term.localizedCaseInsensitiveContains(query)
                || term.mishearings.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var canAddTerm: Bool {
        settings.glossaryList.validation(for: navigation.glossaryDraftTerm) == .valid
    }

    private var newTermValidationMessage: String? {
        guard navigation.glossaryDraftTerm.isEmpty == false else {
            return nil
        }
        return Self.message(for: settings.glossaryList.validation(for: navigation.glossaryDraftTerm))
    }

    private var termCountCaption: String {
        let count = settings.glossaryList.terms.count
        return count == 1 ? "1 term" : "\(count) terms"
    }

    private func termBinding(for term: GlossaryTerm) -> Binding<String> {
        Binding {
            termDrafts[term.id] ?? term.term
        } set: { value in
            termDrafts[term.id] = value
            persistDraft(for: term.id)
        }
    }

    private func mishearingsBinding(for term: GlossaryTerm) -> Binding<String> {
        Binding {
            mishearingDrafts[term.id] ?? term.mishearings.joined(separator: ", ")
        } set: { value in
            mishearingDrafts[term.id] = value
            persistDraft(for: term.id)
        }
    }

    private func validationMessage(for id: UUID) -> String? {
        guard let draft = termDrafts[id] else { return nil }
        return Self.message(for: settings.glossaryList.validation(for: draft, excluding: id))
    }

    private func persistDraft(for id: UUID) {
        guard validationMessage(for: id) == nil,
              let term = termDrafts[id] else {
            return
        }

        settings.updateGlossaryTerm(
            id: id,
            term: term,
            mishearings: Self.parseMishearings(mishearingDrafts[id] ?? "")
        )
    }

    private func addTerm() {
        guard canAddTerm else { return }

        let glossaryTerm = GlossaryTerm(
            term: navigation.glossaryDraftTerm,
            mishearings: Self.parseMishearings(newMishearingsDraft)
        )
        guard settings.addGlossaryTerm(glossaryTerm) else { return }

        selectedTermID = glossaryTerm.id
        navigation.glossaryDraftTerm = ""
        newMishearingsDraft = ""
        isNewTermFocused = true
    }

    private func deleteTerm(id: UUID) {
        settings.deleteGlossaryTerm(id: id)
        termDrafts[id] = nil
        mishearingDrafts[id] = nil
        if selectedTermID == id {
            selectedTermID = nil
        }
    }

    private func synchronizeDrafts() {
        let termIDs = Set(settings.glossaryList.terms.map(\.id))
        termDrafts = termDrafts.filter { termIDs.contains($0.key) }
        mishearingDrafts = mishearingDrafts.filter { termIDs.contains($0.key) }

        for term in settings.glossaryList.terms {
            termDrafts[term.id] = termDrafts[term.id] ?? term.term
            mishearingDrafts[term.id] = mishearingDrafts[term.id]
                ?? term.mishearings.joined(separator: ", ")
        }
    }

    private static func parseMishearings(_ value: String) -> [String] {
        value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    private static func message(for validation: GlossaryList.Validation) -> String? {
        switch validation {
        case .valid:
            nil
        case .empty:
            "Term is required."
        case .duplicate:
            "A term with this spelling already exists."
        }
    }
}
