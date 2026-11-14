import CryptoKit
import Foundation
import Observation
import OSLog

enum HotkeyMode: String, CaseIterable, Identifiable, Sendable {
    case hold
    case toggle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hold:
            "Hold to talk"
        case .toggle:
            "Press to toggle"
        }
    }
}

@MainActor
@Observable
final class AppSettings {
    @ObservationIgnored private let userDefaults: UserDefaults
    /// The only way to change `persistHistory`.
    @ObservationIgnored private(set) lazy var privacyOptIns = PrivacyOptIns(settings: self)

    var hotkeyMode: HotkeyMode {
        didSet {
            userDefaults.set(hotkeyMode.rawValue, forKey: Self.hotkeyModeKey)
        }
    }
    var dictationLocaleID: String {
        didSet {
            userDefaults.set(dictationLocaleID, forKey: Self.dictationLocaleIDKey)
        }
    }
    var targetLanguage: String {
        didSet {
            userDefaults.set(targetLanguage, forKey: Self.targetLanguageKey)
        }
    }
    var tonePreset: TonePreset {
        didSet {
            userDefaults.set(tonePreset.rawValue, forKey: Self.tonePresetKey)
        }
    }
    var customToneText: String {
        didSet {
            userDefaults.set(customToneText, forKey: Self.customToneTextKey)
        }
    }
    var baseURL: String {
        didSet {
            userDefaults.set(baseURL, forKey: Self.baseURLKey)
        }
    }
    var modelName: String {
        didSet {
            userDefaults.set(modelName, forKey: Self.modelNameKey)
        }
    }
    var translationProvider: TranslationProvider {
        didSet {
            userDefaults.set(translationProvider.rawValue, forKey: Self.translationProviderKey)
        }
    }
    var codexPath: String {
        didSet {
            userDefaults.set(codexPath, forKey: Self.codexPathKey)
        }
    }
    var codexModel: String {
        didSet {
            userDefaults.set(codexModel, forKey: Self.codexModelKey)
        }
    }
    var claudePath: String {
        didSet { userDefaults.set(claudePath, forKey: Self.claudePathKey) }
    }
    var claudeModel: String {
        didSet { userDefaults.set(claudeModel, forKey: Self.claudeModelKey) }
    }
    /// Claude Code's config folder (`CLAUDE_CONFIG_DIR`). Empty means `~/.claude`. An app opened from
    /// Finder never sees the shell's variable, so a non-default login needs this.
    var claudeConfigDirectory: String {
        didSet { userDefaults.set(claudeConfigDirectory, forKey: Self.claudeConfigDirectoryKey) }
    }
    var playSounds: Bool {
        didSet {
            userDefaults.set(playSounds, forKey: Self.playSoundsKey)
        }
    }
    var successSound: SuccessSound {
        didSet {
            userDefaults.set(successSound.rawValue, forKey: Self.successSoundKey)
        }
    }
    private var storedMaximumRecordingDurationSeconds: Int
    var maximumRecordingDurationSeconds: Int {
        get {
            storedMaximumRecordingDurationSeconds
        }
        set {
            let normalizedDuration = Self.normalizedRecordingDuration(newValue)
            storedMaximumRecordingDurationSeconds = normalizedDuration
            userDefaults.set(normalizedDuration, forKey: Self.maximumRecordingDurationSecondsKey)
        }
    }
    var avoidBluetoothMicrophone: Bool {
        didSet { userDefaults.set(avoidBluetoothMicrophone, forKey: Self.avoidBluetoothMicrophoneKey) }
    }
    var selectedMicrophoneID: String {
        didSet {
            userDefaults.set(selectedMicrophoneID, forKey: Self.selectedMicrophoneIDKey)
        }
    }
    var dictateWithFnKey: Bool {
        didSet { userDefaults.set(dictateWithFnKey, forKey: Self.dictateWithFnKeyKey) }
    }
    var keepsUsageStats: Bool {
        didSet { userDefaults.set(keepsUsageStats, forKey: Self.keepsUsageStatsKey) }
    }

    var handlesSelfCorrections: Bool {
        didSet { userDefaults.set(handlesSelfCorrections, forKey: Self.handlesSelfCorrectionsKey) }
    }

    var handlesSpokenFormatting: Bool {
        didSet { userDefaults.set(handlesSpokenFormatting, forKey: Self.handlesSpokenFormattingKey) }
    }

    var lowerOtherAudioWhileRecording: Bool {
        didSet { userDefaults.set(lowerOtherAudioWhileRecording, forKey: Self.lowerOtherAudioWhileRecordingKey) }
    }
    var autoPasteEnabled: Bool {
        didSet {
            userDefaults.set(autoPasteEnabled, forKey: Self.autoPasteEnabledKey)
        }
    }
    var streamingDeliveryEnabled: Bool {
        didSet {
            userDefaults.set(streamingDeliveryEnabled, forKey: Self.streamingDeliveryEnabledKey)
        }
    }
    var smartSpacingEnabled: Bool {
        didSet { userDefaults.set(smartSpacingEnabled, forKey: Self.smartSpacingEnabledKey) }
    }
    var matchesSentenceAtCaret: Bool {
        didSet { userDefaults.set(matchesSentenceAtCaret, forKey: Self.matchesSentenceAtCaretKey) }
    }
    var pinDeliveryTarget: Bool {
        didSet { userDefaults.set(pinDeliveryTarget, forKey: Self.pinDeliveryTargetKey) }
    }
    var preferFastTranscription: Bool {
        didSet { userDefaults.set(preferFastTranscription, forKey: Self.preferFastTranscriptionKey) }
    }
    var transformsOnPause: Bool {
        didSet { userDefaults.set(transformsOnPause, forKey: Self.transformsOnPauseKey) }
    }
    /// Changes only through `PrivacyOptIns`, so nothing can skip deleting the file on opt-out.
    fileprivate(set) var persistHistory: Bool {
        didSet {
            userDefaults.set(persistHistory, forKey: Self.persistHistoryKey)
        }
    }
    var showRecordingCue: Bool {
        didSet {
            userDefaults.set(showRecordingCue, forKey: Self.showRecordingCueKey)
        }
    }
    var includeCommonTechTerms: Bool {
        didSet {
            userDefaults.set(includeCommonTechTerms, forKey: Self.includeCommonTechTermsKey)
        }
    }
    var showLiveTranscript: Bool {
        didSet {
            userDefaults.set(showLiveTranscript, forKey: Self.showLiveTranscriptKey)
        }
    }
    var workflowList: WorkflowList {
        didSet {
            persistWorkflowList()
        }
    }
    var glossaryList: GlossaryList {
        didSet {
            persistGlossaryList()
        }
    }
    var glossaryProposals: GlossaryProposalList {
        didSet {
            persistGlossaryProposals()
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        defaultMicrophoneIDProvider: (() -> String)? = nil
    ) {
        self.userDefaults = userDefaults
        self.hotkeyMode = HotkeyMode(rawValue: userDefaults.string(forKey: Self.hotkeyModeKey) ?? "")
            ?? .hold
        self.dictationLocaleID = Self.resolvedDictationLocaleID(in: userDefaults)
        self.targetLanguage = userDefaults.string(forKey: Self.targetLanguageKey) ?? "English"
        self.tonePreset = TonePreset(rawValue: userDefaults.string(forKey: Self.tonePresetKey) ?? "")
            ?? .neutral
        self.customToneText = userDefaults.string(forKey: Self.customToneTextKey) ?? ""
        self.baseURL = userDefaults.string(forKey: Self.baseURLKey) ?? Self.defaultBaseURL
        self.modelName = userDefaults.string(forKey: Self.modelNameKey) ?? Self.defaultModelName
        self.translationProvider = TranslationProvider(
            rawValue: userDefaults.string(forKey: Self.translationProviderKey) ?? ""
        ) ?? .openAICompatible
        self.codexPath = userDefaults.string(forKey: Self.codexPathKey) ?? ""
        self.codexModel = userDefaults.string(forKey: Self.codexModelKey) ?? Self.defaultCodexModel
        self.claudePath = userDefaults.string(forKey: Self.claudePathKey) ?? ""
        self.claudeModel = userDefaults.string(forKey: Self.claudeModelKey) ?? Self.defaultClaudeModel
        self.claudeConfigDirectory = userDefaults.string(forKey: Self.claudeConfigDirectoryKey) ?? ""
        self.playSounds = userDefaults.object(forKey: Self.playSoundsKey) as? Bool ?? true
        self.successSound = SuccessSound(
            rawValue: userDefaults.string(forKey: Self.successSoundKey) ?? ""
        ) ?? .default
        let storedMaximumRecordingDuration = userDefaults.object(
            forKey: Self.maximumRecordingDurationSecondsKey
        ) as? Int
        let normalizedMaximumRecordingDuration = Self.normalizedRecordingDuration(storedMaximumRecordingDuration)
        self.storedMaximumRecordingDurationSeconds = normalizedMaximumRecordingDuration
        if storedMaximumRecordingDuration != normalizedMaximumRecordingDuration {
            userDefaults.set(normalizedMaximumRecordingDuration, forKey: Self.maximumRecordingDurationSecondsKey)
        }
        self.avoidBluetoothMicrophone = userDefaults.object(forKey: Self.avoidBluetoothMicrophoneKey) as? Bool ?? true
        // The app passes the audio catalog's default; Settings itself never queries Core Audio.
        self.selectedMicrophoneID = userDefaults.string(forKey: Self.selectedMicrophoneIDKey)
            ?? defaultMicrophoneIDProvider?()
            ?? ""
        self.dictateWithFnKey = userDefaults.bool(forKey: Self.dictateWithFnKeyKey)
        self.keepsUsageStats = userDefaults.object(forKey: Self.keepsUsageStatsKey) as? Bool ?? true
        // Opt-in: they need a capable model (see TranslationProvider.supportsSpokenEdits).
        self.handlesSelfCorrections = userDefaults.object(forKey: Self.handlesSelfCorrectionsKey) as? Bool ?? false
        self.handlesSpokenFormatting = userDefaults.object(forKey: Self.handlesSpokenFormattingKey) as? Bool ?? false
        self.lowerOtherAudioWhileRecording = userDefaults.bool(forKey: Self.lowerOtherAudioWhileRecordingKey)
        self.autoPasteEnabled = userDefaults.object(forKey: Self.autoPasteEnabledKey) as? Bool ?? false
        self.streamingDeliveryEnabled = userDefaults.object(
            forKey: Self.streamingDeliveryEnabledKey
        ) as? Bool ?? false
        self.smartSpacingEnabled = userDefaults.bool(forKey: Self.smartSpacingEnabledKey)
        self.matchesSentenceAtCaret = userDefaults.bool(forKey: Self.matchesSentenceAtCaretKey)
        self.pinDeliveryTarget = userDefaults.object(forKey: Self.pinDeliveryTargetKey) as? Bool ?? true
        self.preferFastTranscription = userDefaults.object(forKey: Self.preferFastTranscriptionKey) as? Bool ?? false
        self.transformsOnPause = userDefaults.object(forKey: Self.transformsOnPauseKey) as? Bool ?? false
        self.persistHistory = userDefaults.object(forKey: Self.persistHistoryKey) as? Bool ?? false
        self.showRecordingCue = userDefaults.object(forKey: Self.showRecordingCueKey) as? Bool ?? true
        self.includeCommonTechTerms = userDefaults.object(forKey: Self.includeCommonTechTermsKey) as? Bool ?? true
        self.showLiveTranscript = userDefaults.object(forKey: Self.showLiveTranscriptKey) as? Bool ?? true
        self.workflowList = Self.resolvedWorkflowList(in: userDefaults)
        self.glossaryList = Self.resolvedGlossaryList(in: userDefaults)
        self.glossaryProposals = Self.resolvedGlossaryProposals(in: userDefaults)
        if userDefaults.object(forKey: Self.selectedMicrophoneIDKey) == nil,
           selectedMicrophoneID.isEmpty == false {
            userDefaults.set(selectedMicrophoneID, forKey: Self.selectedMicrophoneIDKey)
        }
    }

    var toneInstruction: String {
        get {
            tonePreset.instruction(customText: customToneText)
        }
        set {
            if let preset = TonePreset.allCases.first(where: {
                $0 != .custom && $0.instruction() == newValue
            }) {
                tonePreset = preset
                return
            }

            if newValue.isEmpty {
                tonePreset = .neutral
            } else {
                customToneText = newValue
                tonePreset = .custom
            }
        }
    }

    static let dictationDefaultMigrationMarkerKey = "migratedDictationDefaultToPortugueseBrazil"
    static let workflowMigrationMarkerKey = "migratedFlatSettingsToWorkflowListV1"
    static let defaultDictationLocaleID = "pt-BR"
    static let defaultBaseURL = "https://api.openai.com/v1"
    static let defaultModelName = "gpt-4o-mini"
    /// Empty: the signed-in account's default model. Model names differ between plans, so a fixed
    /// default can be rejected (`gpt-5.4-mini` is, for ChatGPT sign-ins).
    static let defaultCodexModel = ""
    static let defaultClaudeModel = "sonnet"
    static let defaultMaximumRecordingDurationSeconds = 120
    static let minimumRecordingDurationSeconds = 1
    static let maximumRecordingDurationSecondsLimit = 3600

    private static let hotkeyModeKey = "hotkeyMode"
    private static let dictationLocaleIDKey = "dictationLocaleID"
    private static let targetLanguageKey = "targetLanguage"
    private static let tonePresetKey = "tonePreset"
    private static let customToneTextKey = "customToneText"
    private static let baseURLKey = "baseURL"
    private static let modelNameKey = "modelName"
    private static let translationProviderKey = "translationProvider"
    private static let codexPathKey = "codexPath"
    private static let codexModelKey = "codexModel"
    private static let claudePathKey = "claudePath"
    private static let claudeModelKey = "claudeModel"
    private static let claudeConfigDirectoryKey = "claudeConfigDirectory"
    private static let selectedMicrophoneIDKey = "selectedMicrophoneID"
    private static let playSoundsKey = "playSounds"
    private static let successSoundKey = "successSound"
    private static let maximumRecordingDurationSecondsKey = "maximumRecordingDurationSeconds"
    private static let autoPasteEnabledKey = "autoPasteEnabled"
    private static let streamingDeliveryEnabledKey = "streamingDeliveryEnabled"
    private static let persistHistoryKey = "persistHistory"
    private static let showRecordingCueKey = "showRecordingCue"
    private static let includeCommonTechTermsKey = "includeCommonTechTerms"
    private static let showLiveTranscriptKey = "showLiveTranscript"
    private static let avoidBluetoothMicrophoneKey = "avoidBluetoothMicrophone"
    private static let dictateWithFnKeyKey = "dictateWithFnKey"
    private static let handlesSelfCorrectionsKey = "handlesSelfCorrections"
    private static let handlesSpokenFormattingKey = "handlesSpokenFormatting"
    private static let keepsUsageStatsKey = "keepsUsageStats"
    private static let lowerOtherAudioWhileRecordingKey = "lowerOtherAudioWhileRecording"
    private static let matchesSentenceAtCaretKey = "matchesSentenceAtCaret"
    private static let pinDeliveryTargetKey = "pinDeliveryTarget"
    private static let preferFastTranscriptionKey = "preferFastTranscription"
    private static let smartSpacingEnabledKey = "smartSpacingEnabled"
    private static let transformsOnPauseKey = "transformsOnPause"
    private static let workflowListKey = "workflowListV3"
    private static let legacyWorkflowListKey = "workflowListV1"
    private static let glossaryListKey = "glossaryV1"
    private static let glossaryProposalsKey = "glossaryProposalsV1"
    private static let logger = Logger(
        subsystem: "org.syrup.SyrupApp",
        category: "Settings"
    )
    private static let englishLocaleIDsToMigrate: Set<String> = [
        "en",
        "en-US",
        "en_US",
    ]

    private static func normalizedRecordingDuration(_ duration: Int?) -> Int {
        min(
            max(duration ?? defaultMaximumRecordingDurationSeconds, minimumRecordingDurationSeconds),
            maximumRecordingDurationSecondsLimit
        )
    }

    private static func resolvedDictationLocaleID(in userDefaults: UserDefaults) -> String {
        let migrationComplete = userDefaults.bool(forKey: dictationDefaultMigrationMarkerKey)
        let persistedLocaleID = userDefaults.string(forKey: dictationLocaleIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let persistedLocaleID, persistedLocaleID.isEmpty == false else {
            userDefaults.set(defaultDictationLocaleID, forKey: dictationLocaleIDKey)
            userDefaults.set(true, forKey: dictationDefaultMigrationMarkerKey)
            return defaultDictationLocaleID
        }

        guard migrationComplete == false else {
            return persistedLocaleID
        }

        userDefaults.set(true, forKey: dictationDefaultMigrationMarkerKey)

        guard englishLocaleIDsToMigrate.contains(persistedLocaleID) else {
            return persistedLocaleID
        }

        userDefaults.set(defaultDictationLocaleID, forKey: dictationLocaleIDKey)
        return defaultDictationLocaleID
    }

    var maximumRecordingDurationNanoseconds: UInt64 {
        UInt64(maximumRecordingDurationSeconds) * 1_000_000_000
    }

    var activeWorkflow: Workflow {
        workflowList.activeWorkflow
    }

    func setActiveWorkflowID(_ id: UUID) {
        workflowList.setActiveWorkflowID(id)
    }

    func updateWorkflow(id: UUID, _ update: (inout Workflow) -> Void) {
        workflowList.updateWorkflow(id: id, update)
    }

    /// Checks the active workflow's dictation language against what this Mac can transcribe, and
    /// stores the replacement `findReplacement` returns, if any. The workflow and its language are read
    /// before the check; if that workflow's language changed meanwhile, the replacement is dropped, and
    /// switching workflows meanwhile never moves it onto another one.
    func refreshActiveDictationLocale(findReplacement: (String) async -> String?) async {
        let workflow = activeWorkflow
        guard let replacement = await findReplacement(workflow.dictationLocaleID),
              workflowList.workflows.first(where: { $0.id == workflow.id })?.dictationLocaleID == workflow.dictationLocaleID
        else { return }
        updateWorkflow(id: workflow.id) { $0.dictationLocaleID = replacement }
    }

    @discardableResult
    func addWorkflow(from template: WorkflowTemplate) -> UUID {
        let workflow = template.workflow(dictationLocaleID: activeWorkflow.dictationLocaleID)
        workflowList.append(workflow)
        return workflow.id
    }

    @discardableResult
    func duplicateWorkflow(id: UUID) -> UUID? {
        guard let workflow = workflowList.workflows.first(where: { $0.id == id }) else { return nil }
        var duplicate = Workflow(
            id: UUID(),
            name: "\(workflow.name) Copy",
            kind: workflow.kind,
            dictationLocaleID: workflow.dictationLocaleID,
            translationProvider: workflow.translationProvider,
            input: workflow.input,
            includeSelectionContext: workflow.includeSelectionContext,
            speechEngine: workflow.speechEngine,
            corrections: workflow.corrections
        )
        if duplicate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            duplicate.name = "Workflow Copy"
        }
        workflowList.append(duplicate)
        return duplicate.id
    }

    func deleteWorkflow(id: UUID) {
        workflowList.deleteWorkflow(id: id)
    }

    @discardableResult
    func addGlossaryTerm(_ term: GlossaryTerm) -> Bool {
        glossaryList.append(term)
    }

    func updateGlossaryTerm(
        id: UUID,
        term: String,
        mishearings: [String]
    ) {
        glossaryList.update(id: id, term: term, mishearings: mishearings)
    }

    func deleteGlossaryTerm(id: UUID) {
        glossaryList.remove(id: id)
    }

    @discardableResult
    func addGlossaryProposal(_ proposal: GlossaryProposal) -> Bool {
        glossaryProposals.addIfNew(proposal, existingGlossary: glossaryList)
    }

    func removeGlossaryProposal(id: UUID) {
        glossaryProposals.removeProposal(id: id)
    }

    func dismissGlossaryProposal(id: UUID) {
        glossaryProposals.dismiss(id: id)
    }

    static func composedSpeechVocabulary(
        glossary: GlossaryList,
        includeCommonTechTerms: Bool,
        limit: Int = GlossaryList.maximumUsedTerms
    ) -> [String] {
        let candidates = glossary.terms.map(\.term)
            + (includeCommonTechTerms ? CommonTechTerms.terms : [])
        var seen: Set<String> = []

        return candidates.filter { term in
            seen.insert(term.lowercased()).inserted
        }
        .prefix(limit)
        .map { $0 }
    }

    func provider(for workflow: Workflow) -> TranslationProvider {
        workflow.translationProvider ?? translationProvider
    }

    func dictationOptions(for workflow: Workflow) -> DictationOptions {
        dictationOptions(input: workflow.input, provider: provider(for: workflow))
    }

    /// Selected text is not speech, so a "no wait" or "new line" inside it stays as written.
    /// A provider that can't do spoken edits reliably never gets them, whatever the toggles say.
    func dictationOptions(input: WorkflowInput, provider: TranslationProvider) -> DictationOptions {
        guard input == .voice, provider.supportsSpokenEdits else { return .off }
        return DictationOptions(selfCorrections: handlesSelfCorrections, spokenFormatting: handlesSpokenFormatting)
    }

    /// The settings a run of `workflow` is built from, read at the trigger.
    func runInputs(for workflow: Workflow) -> RunInputs {
        RunInputs(
            workflow: workflow,
            provider: provider(for: workflow),
            glossary: glossaryList,
            dictation: dictationOptions(for: workflow),
            speechVocabulary: Self.composedSpeechVocabulary(
                glossary: glossaryList,
                includeCommonTechTerms: includeCommonTechTerms
            )
        )
    }

    func workflow(id: UUID?) -> Workflow {
        id.flatMap { id in workflowList.workflows.first { $0.id == id } } ?? activeWorkflow
    }

    func runConfiguration(workflowID: UUID?, contextText: String? = nil) -> RunConfiguration {
        RunConfigurationBuilder.configuration(for: runInputs(for: workflow(id: workflowID)), contextText: contextText)
    }

    private func persistWorkflowList() {
        if persistVersioned(workflowList, version: WorkflowList.currentVersion, forKey: Self.workflowListKey, name: "workflow_list") {
            userDefaults.set(true, forKey: Self.workflowMigrationMarkerKey)
        }
    }

    private func persistGlossaryList() {
        persistVersioned(glossaryList, version: GlossaryList.currentVersion, forKey: Self.glossaryListKey, name: "glossary")
    }

    private func persistGlossaryProposals() {
        persistVersioned(
            glossaryProposals, version: GlossaryProposalList.currentVersion,
            forKey: Self.glossaryProposalsKey, name: "glossary_proposals"
        )
    }

    /// Writes a versioned JSON blob. A blob saved by a newer build loads empty here (the workflow
    /// list loads the default workflow instead, so there is always one to run) and must survive edits
    /// made in this build, so it is never overwritten.
    @discardableResult
    private func persistVersioned<Value: Encodable>(
        _ value: Value, version: Int, forKey key: String, name: String
    ) -> Bool {
        if let stored = userDefaults.data(forKey: key),
           let header = try? JSONDecoder().decode(BlobVersion.self, from: stored),
           header.version > version {
            Self.logger.notice("settings_persist_skipped blob=\(name, privacy: .public) reason=newer_version")
            return false
        }
        do {
            userDefaults.set(try JSONEncoder().encode(value), forKey: key)
            return true
        } catch {
            Self.logger.error(
                "settings_persist_failed blob=\(name, privacy: .public) code=\((error as NSError).code, privacy: .public)"
            )
            return false
        }
    }

    private static func resolvedGlossaryList(in userDefaults: UserDefaults) -> GlossaryList {
        guard let data = userDefaults.data(forKey: glossaryListKey) else {
            return GlossaryList()
        }

        do {
            let decoded = try JSONDecoder().decode(GlossaryList.self, from: data)
            if decoded.version == GlossaryList.currentVersion { return decoded }
        } catch {
            logger.error("glossary_load_failed code=\((error as NSError).code, privacy: .public)")
        }
        preserveUnusableBlob(data, forKey: glossaryListKey, currentVersion: GlossaryList.currentVersion,
                             name: "glossary", in: userDefaults)
        return GlossaryList()
    }

    private static func resolvedGlossaryProposals(
        in userDefaults: UserDefaults
    ) -> GlossaryProposalList {
        guard let data = userDefaults.data(forKey: glossaryProposalsKey) else {
            return GlossaryProposalList()
        }

        do {
            let decoded = try JSONDecoder().decode(GlossaryProposalList.self, from: data)
            if decoded.version == GlossaryProposalList.currentVersion { return decoded }
        } catch {
            logger.error("glossary_proposals_load_failed code=\((error as NSError).code, privacy: .public)")
        }
        preserveUnusableBlob(data, forKey: glossaryProposalsKey, currentVersion: GlossaryProposalList.currentVersion,
                             name: "glossary_proposals", in: userDefaults)
        return GlossaryProposalList()
    }

    /// Copies a blob this build cannot use (an older version, or data that does not decode) to a backup
    /// key named by its digest, before the first edit replaces it. The copy is idempotent across launches.
    /// A newer build's blob is left alone: it stays in place, and `persistVersioned` never overwrites it.
    /// Only the newest backup per key is kept, since a backup holds user content (glossary terms,
    /// workflow instructions) that would otherwise outlive the person deleting it from Settings: the
    /// current blob's backup is the newest, so writing it, or finding it already there, removes the
    /// key's others.
    static func preserveUnusableBlob(
        _ data: Data, forKey key: String, currentVersion: Int, name: String, in userDefaults: UserDefaults
    ) {
        if let header = try? JSONDecoder().decode(BlobVersion.self, from: data), header.version > currentVersion {
            return
        }
        let backupKey = unusableBlobBackupKey(for: data, key: key)
        removeUnusableBlobBackups(forKey: key, keeping: backupKey, in: userDefaults)
        guard userDefaults.data(forKey: backupKey) == nil else { return }
        userDefaults.set(data, forKey: backupKey)
        logger.notice("settings_blob_preserved blob=\(name, privacy: .public)")
    }

    private static func removeUnusableBlobBackups(forKey key: String, keeping kept: String, in userDefaults: UserDefaults) {
        for backup in userDefaults.dictionaryRepresentation().keys
        where backup.hasPrefix(key + ".unreadable.") && backup != kept {
            userDefaults.removeObject(forKey: backup)
        }
    }

    static func unusableBlobBackupKey(for data: Data, key: String) -> String {
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(key).unreadable.\(digest)"
    }

    private struct BlobVersion: Decodable {
        let version: Int
    }

    private static func resolvedWorkflowList(in userDefaults: UserDefaults) -> WorkflowList {
        let current = userDefaults.data(forKey: workflowListKey)
        let data = current ?? userDefaults.data(forKey: legacyWorkflowListKey)
        if let data,
           let decoded = try? JSONDecoder().decode(WorkflowList.self, from: data),
           (1...WorkflowList.currentVersion).contains(decoded.version) {
            var upgraded = decoded
            upgraded.version = WorkflowList.currentVersion
            if current == nil || decoded.version < WorkflowList.currentVersion,
               let upgradedData = try? JSONEncoder().encode(upgraded) {
                userDefaults.set(upgradedData, forKey: workflowListKey)
            }
            return upgraded
        }

        if let current {
            preserveUnusableBlob(current, forKey: workflowListKey, currentVersion: WorkflowList.currentVersion,
                                 name: "workflow_list", in: userDefaults)
            // A corrupt or older current list falls back to the person's older one, if that still reads,
            // before the default workflow; the first edit saves it. A newer build's list does not: it
            // loads the default workflow, as AGENTS.md says, rather than a stale one.
            let isNewer = (try? JSONDecoder().decode(BlobVersion.self, from: current))
                .map { $0.version > WorkflowList.currentVersion } ?? false
            if isNewer == false,
               let legacy = userDefaults.data(forKey: legacyWorkflowListKey),
               let decoded = try? JSONDecoder().decode(WorkflowList.self, from: legacy),
               (1...WorkflowList.currentVersion).contains(decoded.version) {
                var upgraded = decoded
                upgraded.version = WorkflowList.currentVersion
                return upgraded
            }
        }
        let migrated = migratedWorkflowList(in: userDefaults)
        if data == nil {
            if let data = try? JSONEncoder().encode(migrated) {
                userDefaults.set(data, forKey: workflowListKey)
            }
            userDefaults.set(true, forKey: workflowMigrationMarkerKey)
        }
        return migrated
    }

    private static func migratedWorkflowList(in userDefaults: UserDefaults) -> WorkflowList {
        let workflow = Workflow(
            id: UUID(),
            name: "Translate",
            kind: .translation(
                targetLanguage: userDefaults.string(forKey: targetLanguageKey) ?? "English",
                tonePreset: TonePreset(rawValue: userDefaults.string(forKey: tonePresetKey) ?? "") ?? .neutral,
                customToneText: userDefaults.string(forKey: customToneTextKey) ?? ""
            ),
            dictationLocaleID: resolvedDictationLocaleID(in: userDefaults),
            translationProvider: nil
        )
        return WorkflowList(workflows: [workflow])
    }
}

/// The only way to change the history opt-in. Each `AppSettings` makes exactly one, and only this
/// file can set the setting or make another, so there is no second owner without the store.
/// `AppState` attaches the store the opt-out must empty, the app's history store, once when it starts.
@MainActor
final class PrivacyOptIns {
    private unowned let settings: AppSettings
    private var history: HistoryStore?
    private static let logger = Logger(subsystem: "org.syrup.SyrupApp", category: "Settings")

    fileprivate init(settings: AppSettings) {
        self.settings = settings
    }

    /// Once: attaching another store later would let an opt-out miss what the first one kept.
    func attach(history: HistoryStore) {
        precondition(self.history == nil, "The privacy opt-ins already have their store")
        self.history = history
    }

    #if DEBUG
    /// Tests only: lets another `AppState` on the same settings attach its store, standing in for a
    /// relaunch. Release builds cannot re-attach.
    func detachForTesting() {
        history = nil
    }
    #endif

    /// Keep history. The store acts first: turning it off deletes the file, and the setting follows
    /// only if that worked, so it never claims an opt-out it didn't honor. With no store attached,
    /// turning it off is refused: a file from an earlier launch may be on disk, with nothing to delete it.
    func setPersistHistory(_ isEnabled: Bool) async {
        guard let history else {
            if isEnabled || settings.persistHistory == false {
                settings.persistHistory = isEnabled
            } else {
                Self.logger.error("privacy_opt_out_refused setting=persist_history reason=no_store")
            }
            return
        }
        if await history.setPersistenceEnabled(isEnabled) { settings.persistHistory = isEnabled }
    }
}
