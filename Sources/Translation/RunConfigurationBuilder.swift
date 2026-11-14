import Foundation

/// The settings a run is built from, read once at the trigger so later edits reach only the next run.
struct RunInputs: Sendable {
    let workflow: Workflow
    let provider: TranslationProvider
    let glossary: GlossaryList
    let dictation: DictationOptions
    let speechVocabulary: [String]
}

/// The only place a `RunConfiguration` is assembled. Each kind of run has one entry point:
/// a workflow run (with or without captured selection), a revision before and after its spoken
/// adjustment is known, and a retry of a failed history record.
enum RunConfigurationBuilder {
    /// A workflow run. `contextText` is the captured selection: the input of a selected-text workflow,
    /// or reference context for a voice workflow that opted in. Either way the history snapshot is
    /// contextual and its instruction never contains the selection.
    static func configuration(for inputs: RunInputs, contextText: String? = nil) -> RunConfiguration {
        let workflow = inputs.workflow
        let instructionContext = workflow.input == .voice && workflow.includeSelectionContext ? contextText : nil
        let snapshotInstruction = PromptBuilder.instruction(
            for: workflow.kind, glossary: inputs.glossary, dictation: inputs.dictation
        )
        let instruction = instructionContext == nil ? snapshotInstruction : PromptBuilder.instruction(
            for: workflow.kind, glossary: inputs.glossary, context: instructionContext, dictation: inputs.dictation
        )
        let purpose: RunPurpose = if case .transcribeOnly(let cleanup, let symbols) = workflow.kind {
            .transcribeOnly(cleanup: cleanup, spokenSymbols: symbols)
        } else {
            .dictation
        }
        return RunConfiguration(
            workflowID: workflow.id,
            workflowName: workflow.name,
            dictationLocaleID: workflow.dictationLocaleID,
            instruction: instruction,
            provider: inputs.provider,
            transformation: snapshot(for: workflow, instruction: snapshotInstruction,
                                     isContextual: workflow.input == .selection || instructionContext != nil),
            purpose: purpose,
            contextText: contextText,
            speechVocabulary: inputs.speechVocabulary,
            speechEngine: workflow.speechEngine,
            corrections: workflow.corrections
        )
    }

    /// A revision at its trigger: the active workflow's speech settings and provider, and the captured
    /// earlier result. The instruction is empty until the spoken adjustment is transcribed.
    static func revision(of active: RunConfiguration, base: String) -> RunConfiguration {
        RunConfiguration(
            workflowID: active.workflowID,
            workflowName: active.workflowName,
            dictationLocaleID: active.dictationLocaleID,
            instruction: "",
            provider: active.provider,
            transformation: .revision(adjustment: "", instruction: ""),
            purpose: .revision(base: base),
            speechVocabulary: active.speechVocabulary,
            speechEngine: active.speechEngine,
            corrections: active.corrections
        )
    }

    /// A revision once its spoken adjustment is known. The instruction carries the adjustment, the
    /// glossary block frozen at the trigger, and the output contract.
    static func revision(
        _ configuration: RunConfiguration, adjustment: String, glossaryBlock: String?
    ) -> RunConfiguration {
        let instruction = revisionInstruction(adjustment: adjustment, glossaryBlock: glossaryBlock)
        return RunConfiguration(
            workflowID: configuration.workflowID,
            workflowName: configuration.workflowName,
            dictationLocaleID: configuration.dictationLocaleID,
            instruction: instruction,
            provider: configuration.provider,
            transformation: .revision(adjustment: adjustment, instruction: instruction),
            purpose: configuration.purpose,
            contextText: configuration.contextText,
            speechVocabulary: configuration.speechVocabulary,
            speechEngine: configuration.speechEngine,
            corrections: configuration.corrections
        )
    }

    /// A retry of a failed record with `provider`, always with the current glossary. The instruction is
    /// composed again from the parts the record kept: target and tone, the custom workflow's own
    /// instruction, or the spoken adjustment. Only a custom record from an older build, which kept just
    /// the rendered text, has its glossary block swapped in place. Returns the configuration and the
    /// text to transform, or nil when a revision record lost its captured base.
    static func retry(
        transformation: TransformationSnapshot, transcript: String, output: String?,
        provider: TranslationProvider, activeWorkflow: Workflow,
        glossary: GlossaryList, dictation: DictationOptions
    ) -> (configuration: RunConfiguration, inputText: String)? {
        let inputText: String
        let purpose: RunPurpose
        switch transformation {
        case .revision:
            guard let output else { return nil }
            inputText = output
            purpose = .revision(base: output)
        case .translation, .custom, .contextual:
            inputText = transcript
            purpose = .dictation
        }
        let instruction = switch transformation {
        case .translation(let targetLanguage, let toneInstruction):
            PromptBuilder.systemPrompt(
                targetLanguage: targetLanguage, toneInstruction: toneInstruction,
                glossary: glossary, dictation: dictation
            )
        case .custom(_, _, let prompt?):
            PromptBuilder.instruction(
                for: .custom(instruction: prompt.base, enforceOutputContract: prompt.enforcesOutputContract),
                glossary: glossary
            )
        case .custom(_, let rendered, nil):
            PromptBuilder.replacingGlossary(in: rendered, with: glossary)
        case .revision(let adjustment, _):
            revisionInstruction(adjustment: adjustment, glossaryBlock: PromptBuilder.glossaryBlock(for: glossary))
        case .contextual(_, let rendered):
            rendered
        }
        let configuration = RunConfiguration(
            workflowID: activeWorkflow.id,
            workflowName: transformation.displayName,
            dictationLocaleID: activeWorkflow.dictationLocaleID,
            instruction: instruction,
            provider: provider,
            transformation: transformation,
            purpose: purpose
        )
        return (configuration, inputText)
    }

    /// A revision's instruction: the adjustment, the glossary block, and the output contract.
    private static func revisionInstruction(adjustment: String, glossaryBlock: String?) -> String {
        PromptBuilder.compose(
            base: PromptBuilder.revisionInstruction(adjustment: adjustment),
            glossary: glossaryBlock,
            context: nil,
            contract: PromptBuilder.outputContract
        )
    }

    private static func snapshot(
        for workflow: Workflow, instruction: String, isContextual: Bool
    ) -> TransformationSnapshot {
        if isContextual {
            return .contextual(workflowName: workflow.name, instruction: instruction)
        }
        switch workflow.kind {
        case .translation(let targetLanguage, let tonePreset, let customToneText):
            return .translation(
                targetLanguage: targetLanguage,
                toneInstruction: tonePreset.instruction(customText: customToneText)
            )
        case .custom(let base, let enforcesOutputContract):
            return .custom(
                workflowName: workflow.name, instruction: instruction,
                prompt: .init(base: base, enforcesOutputContract: enforcesOutputContract)
            )
        case .transcribeOnly:
            return .contextual(workflowName: workflow.name, instruction: "")
        }
    }
}
