import Foundation

enum WorkflowKind: Equatable, Sendable, Codable {
    case translation(targetLanguage: String, tonePreset: TonePreset, customToneText: String)
    case custom(instruction: String, enforceOutputContract: Bool)
    case transcribeOnly(cleanup: Bool, spokenSymbols: Bool = false)

    private enum CodingKeys: String, CodingKey { case translation, custom, transcribeOnly }
    private enum OptionKeys: String, CodingKey {
        case targetLanguage, tonePreset, customToneText, instruction, enforceOutputContract, cleanup, spokenSymbols
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected one workflow kind"))
        }
        let options = try container.nestedContainer(keyedBy: OptionKeys.self, forKey: key)
        switch key {
        case .translation:
            self = .translation(targetLanguage: try options.decode(String.self, forKey: .targetLanguage),
                                tonePreset: try options.decode(TonePreset.self, forKey: .tonePreset),
                                customToneText: try options.decode(String.self, forKey: .customToneText))
        case .custom:
            self = .custom(instruction: try options.decode(String.self, forKey: .instruction),
                           enforceOutputContract: try options.decode(Bool.self, forKey: .enforceOutputContract))
        case .transcribeOnly:
            self = .transcribeOnly(cleanup: try options.decode(Bool.self, forKey: .cleanup),
                                   spokenSymbols: try options.decodeIfPresent(Bool.self, forKey: .spokenSymbols) ?? false)
        }
    }

    var isTranscribeOnly: Bool {
        switch self {
        case .translation, .custom: false
        case .transcribeOnly: true
        }
    }
}

enum WorkflowInput: String, Equatable, Sendable, Codable {
    case voice
    case selection
}

struct Workflow: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var name: String
    var kind: WorkflowKind { didSet { normalizeInput() } }
    var dictationLocaleID: String
    var translationProvider: TranslationProvider?
    var input: WorkflowInput = .voice {
        didSet { if kind.isTranscribeOnly { input = .voice } }
    }
    var includeSelectionContext = false {
        didSet { if kind.isTranscribeOnly { includeSelectionContext = false } }
    }
    var corrections: [Correction] = []
    var speechEngine: SpeechEngine = .apple

    init(
        id: UUID,
        name: String,
        kind: WorkflowKind,
        dictationLocaleID: String,
        translationProvider: TranslationProvider?,
        input: WorkflowInput = .voice,
        includeSelectionContext: Bool = false,
        speechEngine: SpeechEngine = .apple,
        corrections: [Correction] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.dictationLocaleID = dictationLocaleID
        self.translationProvider = translationProvider
        self.input = input
        self.includeSelectionContext = includeSelectionContext
        self.corrections = corrections
        self.speechEngine = speechEngine
        normalizeInput()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(WorkflowKind.self, forKey: .kind)
        dictationLocaleID = try container.decode(String.self, forKey: .dictationLocaleID)
        translationProvider = try container.decodeProviderIfPresent(forKey: .translationProvider)
        input = try container.decodeIfPresent(WorkflowInput.self, forKey: .input) ?? .voice
        includeSelectionContext = try container.decodeIfPresent(
            Bool.self,
            forKey: .includeSelectionContext
        ) ?? false
        speechEngine = try container.decodeIfPresent(SpeechEngine.self, forKey: .speechEngine) ?? .apple
        corrections = try container.decodeIfPresent([Correction].self, forKey: .corrections) ?? []
        normalizeInput()
    }

    fileprivate mutating func normalizeInput() {
        if kind.isTranscribeOnly {
            input = .voice
            includeSelectionContext = false
            translationProvider = nil
        }
        if speechEngine.supports(localeID: dictationLocaleID) == false {
            speechEngine = .apple
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case dictationLocaleID
        case translationProvider
        case input
        case includeSelectionContext
        case speechEngine
        case corrections
    }
}

struct WorkflowList: Equatable, Sendable, Codable {
    static let currentVersion = 3

    var version: Int
    private(set) var workflows: [Workflow]
    private(set) var appRouting: [String: UUID]
    var activeWorkflowID: UUID

    var activeWorkflow: Workflow {
        workflows.first { $0.id == activeWorkflowID } ?? workflows[0]
    }

    init(workflows: [Workflow], activeWorkflowID: UUID? = nil, appRouting: [String: UUID] = [:]) {
        precondition(workflows.isEmpty == false, "WorkflowList requires at least one workflow")
        self.version = Self.currentVersion
        self.workflows = workflows
        self.appRouting = appRouting
        self.activeWorkflowID = activeWorkflowID ?? workflows[0].id
        normalize()
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        workflows = try container.decode([Workflow].self, forKey: .workflows)
        appRouting = try container.decodeIfPresent([String: UUID].self, forKey: .appRouting) ?? [:]
        activeWorkflowID = try container.decode(UUID.self, forKey: .activeWorkflowID)
        normalize()
    }

    mutating func setActiveWorkflowID(_ id: UUID) {
        guard workflows.contains(where: { $0.id == id }) else { return }
        activeWorkflowID = id
        normalize()
    }

    mutating func updateWorkflow(id: UUID, _ update: (inout Workflow) -> Void) {
        guard let index = workflows.firstIndex(where: { $0.id == id }) else { return }
        update(&workflows[index])
        normalize()
    }

    mutating func append(_ workflow: Workflow, activate: Bool = true) {
        workflows.append(workflow)
        normalize()
        if activate {
            activeWorkflowID = workflow.id
        }
    }

    mutating func deleteWorkflow(id: UUID) {
        guard workflows.count > 1 else { return }
        workflows.removeAll { $0.id == id }
        normalize()
    }

    func routedWorkflowID(for bundleID: String?) -> UUID? {
        guard appRouting.isEmpty == false, let bundleID else { return nil }
        return appRouting[bundleID]
    }

    mutating func routeApplication(_ bundleID: String, to workflowID: UUID?) {
        appRouting[bundleID] = workflowID
        normalize()
    }

    private mutating func normalize() {
        for index in workflows.indices { workflows[index].normalizeInput() }
        appRouting = appRouting.filter { entry in workflows.contains { $0.id == entry.value } }
        if workflows.isEmpty == false, workflows.contains(where: { $0.id == activeWorkflowID }) == false {
            activeWorkflowID = workflows[0].id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case workflows
        case appRouting
        case activeWorkflowID
    }
}

struct WorkflowTemplate: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let kind: WorkflowKind
    let input: WorkflowInput
    let includeSelectionContext: Bool

    init(
        id: String,
        name: String,
        kind: WorkflowKind,
        input: WorkflowInput = .voice,
        includeSelectionContext: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.input = input
        self.includeSelectionContext = includeSelectionContext
    }

    func workflow(dictationLocaleID: String) -> Workflow {
        Workflow(
            id: UUID(),
            name: name,
            kind: kind,
            dictationLocaleID: dictationLocaleID,
            translationProvider: nil,
            input: input,
            includeSelectionContext: includeSelectionContext
        )
    }

    static func templates(
        targetLanguage: String = "English",
        tonePreset: TonePreset = .neutral,
        customToneText: String = ""
    ) -> [WorkflowTemplate] {
        [
            WorkflowTemplate(
                id: "translate",
                name: "Translate",
                kind: .translation(
                    targetLanguage: targetLanguage,
                    tonePreset: tonePreset,
                    customToneText: customToneText
                )
            ),
            WorkflowTemplate(
                id: "polish",
                name: "Polish",
                kind: .custom(
                    instruction: "Rewrite the text as clean written text in the same language it was dictated in. Fix punctuation, remove fillers and false starts, keep the meaning and register.",
                    enforceOutputContract: true
                )
            ),
            WorkflowTemplate(
                id: "reply-draft",
                name: "Reply Draft",
                kind: .custom(
                    instruction: "Turn the dictation into a concise, professional reply in English, suitable for Slack or email. Keep it under 120 words unless the content requires more.",
                    enforceOutputContract: true
                ),
                includeSelectionContext: true
            ),
            WorkflowTemplate(
                id: "summarize",
                name: "Summarize",
                kind: .custom(
                    instruction: "Summarize the dictation as short bullet points in English. Keep names, numbers, and decisions.",
                    enforceOutputContract: true
                )
            ),
            WorkflowTemplate(
                id: "prompt-writer",
                name: "Prompt Writer",
                kind: .custom(
                    instruction: "Rewrite the dictation as a clear, well-structured prompt for an AI coding assistant. State the goal, the context, and the constraints explicitly.",
                    enforceOutputContract: true
                )
            ),
            WorkflowTemplate(
                id: "summarize-selection",
                name: "Summarize Selection",
                kind: .custom(
                    instruction: "Summarize the provided text as short bullet points in English. Keep names, numbers, and decisions.",
                    enforceOutputContract: true
                ),
                input: .selection
            ),
            WorkflowTemplate(
                id: "transcribe",
                name: "Transcribe",
                kind: .transcribeOnly(cleanup: true)
            ),
            WorkflowTemplate(
                id: "translate-selection",
                name: "Translate Selection",
                kind: .translation(
                    targetLanguage: targetLanguage,
                    tonePreset: tonePreset,
                    customToneText: customToneText
                ),
                input: .selection
            ),
        ]
    }
}

enum RunPurpose: Equatable, Sendable {
    case dictation
    /// Revises a captured earlier result; the spoken adjustment becomes the instruction.
    case revision(base: String)
    case transcribeOnly(cleanup: Bool, spokenSymbols: Bool = false)

    var isTransformation: Bool {
        if case .transcribeOnly = self { return false }
        return true
    }

    var isRevision: Bool {
        if case .revision = self { return true }
        return false
    }
}

struct RunConfiguration: Equatable, Sendable {
    let workflowID: UUID
    let workflowName: String
    let dictationLocaleID: String
    let instruction: String
    let provider: TranslationProvider
    let transformation: TransformationSnapshot
    var purpose: RunPurpose = .dictation
    var contextText: String? = nil
    var speechVocabulary: [String] = []
    var speechEngine: SpeechEngine = .apple
    var corrections: [Correction] = []
}
