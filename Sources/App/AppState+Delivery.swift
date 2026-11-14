import Foundation

/// Transformation and the single delivery commit point, shared by voice, selected-text, and retry runs.
extension AppState {
    func runSelectionPipeline(
        runID: UUID,
        configuration: RunConfiguration
    ) async {
        do {
            guard isCurrentRun(runID), let selectedText = configuration.contextText else {
                throw CancellationError()
            }
            try Task.checkCancellation()

            _ = try await translateAndDeliver(
                inputText: selectedText,
                transcript: selectedText,
                recordTranscript: "",
                configuration: configuration,
                runID: runID
            )
            finishRunSucceeded(runID)
        } catch {
            finishRunFailed(runID, error: error)
        }
    }

    // MARK: - Transformation and delivery

    func translateAndDeliver(
        inputText: String,
        transcript: String,
        recordTranscript: String? = nil,
        configuration: RunConfiguration,
        runID: UUID,
        preparedTransformerTask: Task<any TextTransformer, Never>? = nil,
        recordReleaseToClipboard: Bool = false
    ) async throws -> String {
        guard isCurrentRun(runID) else { throw CancellationError() }
        try Task.checkCancellation()
        let transformerTask: Task<any TextTransformer, Never>
        if let preparedTransformerTask = preparedTransformerTask ?? activeRun?.preparedTransformer {
            transformerTask = preparedTransformerTask
        } else {
            metrics.begin(.translationConfiguration, runID: runID)
            let snapshot = transformerProvider.snapshot(for: configuration.provider)
            transformerTask = Task { [metrics] in
                let transformer = await snapshot.transformer(instruction: configuration.instruction)
                await MainActor.run {
                    metrics.end(.translationConfiguration, runID: runID)
                }
                return transformer
            }
        }

        let transformer = await withTaskCancellationHandler {
            await transformerTask.value
        } onCancel: {
            transformerTask.cancel()
        }
        guard isCurrentRun(runID) else {
            throw CancellationError()
        }
        try Task.checkCancellation()

        let recordedTranscript = recordTranscript ?? transcript
        if let run = activeRun,
           (run.streamingDeliveryEnabled && run.autoPasteEnabled && autoPaster.isTrusted)
                || (run.showRecordingCue && recordingCue != nil),
           let streamingTransformer = transformer as? any StreamingTextTransformer,
           let streamedText = try await streamAndDeliver(
               inputText: inputText,
               transcript: recordedTranscript,
               configuration: configuration,
               runID: runID,
               transformer: streamingTransformer,
               recordReleaseToClipboard: recordReleaseToClipboard
           ) {
            return streamedText
        }

        let transformedText: String
        do {
            metrics.begin(.translation, runID: runID)
            transformedText = try await transformer.transform(
                inputText,
                instruction: configuration.instruction
            )
            metrics.end(.translation, runID: runID)
        } catch {
            throw recordFailedDelivery(error, transcript: recordedTranscript, inputText: inputText,
                                       configuration: configuration, runID: runID)
        }

        return try await commitAtomicOutput(transformedText, transcript: recordedTranscript,
            configuration: configuration, runID: runID, recordReleaseToClipboard: recordReleaseToClipboard)
    }

    func commitAtomicOutput(
        _ transformedText: String, transcript: String, configuration: RunConfiguration,
        runID: UUID, recordReleaseToClipboard: Bool
    ) async throws -> String {
        guard let run = activeRun, run.id == runID else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        let fitted = await delivery.sentenceFit(for: transformedText, run: run)
        guard isCurrentRun(runID) else { throw CancellationError() }
        try Task.checkCancellation()

        try commit(
            CompletedOutput(output: transformedText, fitted: fitted, transcript: transcript, configuration: configuration),
            runID: runID, recordReleaseToClipboard: recordReleaseToClipboard
        )
        metrics.recordDeliveryMode(.atomic, runID: runID)
        try await delivery.autoPaste(fitted.text, run: run, knownContext: fitted.context,
                                     isCurrentRun: currentRunCheck(runID))
        return transformedText
    }

    /// The single commit point for every delivered result: clipboard, history, and the point after
    /// which cancel no longer applies. A failed clipboard write keeps the result for Copy Result.
    func commit(_ completed: CompletedOutput, runID: UUID, recordReleaseToClipboard: Bool) throws {
        if let failure = activeRun?.failure { throw failure }
        metrics.begin(.clipboardWrite, runID: runID)
        do {
            try pasteboard.write(completed.fitted.text)
            pendingClipboardResult = nil
        } catch {
            pendingClipboardResult = PendingClipboardResult(
                output: completed.output,
                delivered: completed.fitted.text,
                transcript: completed.transcript,
                transformation: completed.configuration.transformation,
                provider: completed.configuration.provider
            )
            throw error
        }
        metrics.end(.clipboardWrite, runID: runID)
        if recordReleaseToClipboard {
            metrics.end(.releaseToClipboard, runID: runID)
        }

        appendRecord(
            transcript: completed.transcript,
            output: completed.output,
            transformation: completed.configuration.transformation,
            outcome: .success
        )
        activeRun?.deliveryCommitted = true
    }

    /// Records a failed transformation once, in history and on the run, and returns the error to show.
    /// When streamed text already reached the editor, the message says partial text may remain.
    private func recordFailedDelivery(
        _ error: any Error, transcript: String, inputText: String,
        configuration: RunConfiguration, runID: UUID, typist: (any StreamingTyping)? = nil
    ) -> any Error {
        let postedText = typist?.hasPostedText == true
        let deliveryError: any Error = postedText ? PipelineError.streamingFailed(userMessage(for: error)) : error
        guard isCurrentRun(runID), Task.isCancelled == false else { return deliveryError }
        activeRun?.failedRecordID = appendRecord(
            transcript: transcript,
            output: configuration.purpose.isRevision ? inputText : nil,
            transformation: configuration.transformation,
            outcome: .failed(message: userMessage(for: deliveryError))
        )
        if postedText {
            metrics.recordDeliveryMode(.streamedPartial, runID: runID)
        }
        return deliveryError
    }

    private func currentRunCheck(_ runID: UUID) -> @MainActor () -> Bool {
        { [weak self] in self?.isCurrentRun(runID) == true }
    }

    private func streamAndDeliver(
        inputText: String,
        transcript: String,
        configuration: RunConfiguration,
        runID: UUID,
        transformer: any StreamingTextTransformer,
        recordReleaseToClipboard: Bool
    ) async throws -> String? {
        guard let run = activeRun, run.id == runID else { throw CancellationError() }
        var typesIntoEditor = run.streamingDeliveryEnabled && run.autoPasteEnabled && autoPaster.isTrusted
        if typesIntoEditor {
            typesIntoEditor = await delivery.targetIsCurrent(run)
            guard isCurrentRun(runID) else { throw CancellationError() }
            try Task.checkCancellation()
        }
        let typist: any StreamingTyping = typesIntoEditor ? streamingTypistFactory() : PreviewOnlyTypist()
        typist.setTargetValidator { [weak self, weak run] in
            guard let self, let run, self.isCurrentRun(runID) else { return false }
            return await self.delivery.targetIsCurrent(run)
        }
        typist.onTextPosted = { [metrics] in metrics.end(.firstVisibleOutput, runID: runID) }
        do {
            try typist.start()
        } catch {
            return nil
        }
        let keepsWrapperQuotes = ModelOutputNormalizer.requestsQuotes(
            input: inputText,
            instruction: configuration.instruction
        )
        typist.setKeepsWrapperQuotes(keepsWrapperQuotes)
        activeRun?.streamingTypist = typist
        defer {
            clearStreamingTypistOwnership(ifOwnedBy: typist)
        }

        var fullText = ""
        var receivedFirstDelta = false
        var contextPending = typesIntoEditor && (run.smartSpacingEnabled || run.matchesSentenceAtCaret)
        var typedContext: CaretContext?
        var readTypedContext = false
        var atomicFallbackText: String?
        metrics.begin(.translation, runID: runID)
        metrics.begin(.streamingFirstDelta, runID: runID)
        metrics.begin(.firstVisibleOutput, runID: runID)

        do {
            for try await delta in transformer.transformStream(
                inputText,
                instruction: configuration.instruction
            ) {
                guard isCurrentRun(runID) else {
                    throw CancellationError()
                }
                try Task.checkCancellation()

                if receivedFirstDelta == false {
                    receivedFirstDelta = true
                    metrics.end(.streamingFirstDelta, runID: runID)
                }
                fullText += delta
                if run.showRecordingCue, recordingCue?.updateOutput(fullText) == true {
                    metrics.end(.firstVisibleOutput, runID: runID)
                }
                if contextPending, !delta.isEmpty {
                    contextPending = false
                    let context: CaretContext?
                    if run.matchesSentenceAtCaret || delta.first?.isWhitespace == false {
                        context = await run.deliveryTarget?.caretContext(readsSentence: run.matchesSentenceAtCaret)
                    } else {
                        context = nil
                    }
                    guard isCurrentRun(runID), !Task.isCancelled else { throw CancellationError() }
                    typedContext = context
                    readTypedContext = run.matchesSentenceAtCaret
                    if run.smartSpacingEnabled, delta.first?.isWhitespace == false, context?.precedingWordCharacter == true {
                        typist.addLeadingSpace()
                    }
                    if run.matchesSentenceAtCaret, let context {
                        typist.setSentenceFit(context: context, protectedTerms: run.protectedTerms)
                    }
                }
                typist.append(delta)
            }
            metrics.end(.translation, runID: runID)
        } catch is CancellationError {
            cancelStreamingTypist(ifOwnedBy: typist)
            if typist.hasPostedText {
                metrics.recordDeliveryMode(.streamedPartial, runID: runID)
            }
            throw CancellationError()
        } catch StreamingTransformError.requiresAtomicFallback {
            cancelStreamingTypist(ifOwnedBy: typist)
            do {
                atomicFallbackText = try await transformer.transformAfterStreamingFallback(
                    inputText,
                    instruction: configuration.instruction
                )
                metrics.end(.translation, runID: runID)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw recordFailedDelivery(error, transcript: transcript, inputText: inputText,
                                           configuration: configuration, runID: runID, typist: typist)
            }
        } catch {
            cancelStreamingTypist(ifOwnedBy: typist)
            throw recordFailedDelivery(error, transcript: transcript, inputText: inputText,
                                       configuration: configuration, runID: runID, typist: typist)
        }

        guard isCurrentRun(runID) else {
            cancelStreamingTypist(ifOwnedBy: typist)
            throw CancellationError()
        }
        try Task.checkCancellation()

        let transformedText: String
        if let atomicFallbackText {
            transformedText = atomicFallbackText
        } else {
            await typist.finish()
            guard isCurrentRun(runID) else {
                cancelStreamingTypist(ifOwnedBy: typist)
                throw CancellationError()
            }
            try Task.checkCancellation()
            transformedText = ModelOutputNormalizer.normalize(
                fullText,
                keepsWrapperQuotes: keepsWrapperQuotes
            )
        }
        guard transformedText.isEmpty == false else {
            throw recordFailedDelivery(TranslationError.emptyResponse, transcript: transcript, inputText: inputText,
                                       configuration: configuration, runID: runID, typist: typist)
        }

        // The typist fitted what it typed with the context it read; reuse it so the clipboard matches.
        let fitted: FittedText
        if readTypedContext {
            fitted = FittedText(text: typedContext.map {
                SentenceFit.apply(transformedText, context: $0, protectedTerms: run.protectedTerms)
            } ?? transformedText, context: typedContext)
        } else {
            fitted = await delivery.sentenceFit(for: transformedText, run: run)
            guard isCurrentRun(runID) else { throw CancellationError() }
            try Task.checkCancellation()
        }

        try commit(
            CompletedOutput(output: transformedText, fitted: fitted, transcript: transcript, configuration: configuration),
            runID: runID, recordReleaseToClipboard: recordReleaseToClipboard
        )

        if typist.hasPostedText == false, (atomicFallbackText != nil || typesIntoEditor == false) {
            try await delivery.autoPaste(fitted.text, run: run, knownContext: fitted.context,
                                         isCurrentRun: currentRunCheck(runID))
        }

        if atomicFallbackText != nil {
            if typist.hasPostedText {
                metrics.recordDeliveryMode(.streamedPartial, runID: runID)
                feedback.notifyError(message: "Streaming stopped - the full result was copied.")
            } else {
                metrics.recordDeliveryMode(.atomic, runID: runID)
            }
            return transformedText
        }

        if let stopReason = typist.stopReason {
            metrics.recordDeliveryMode(.streamedPartial, runID: runID)
            delivery.notifyStreamingStopped(stopReason)
        } else {
            metrics.recordDeliveryMode(typesIntoEditor ? .streamed : .atomic, runID: runID)
        }
        return transformedText
    }

    func retryPipeline(
        record: DictationRecord,
        inputText: String,
        configuration: RunConfiguration,
        runID: UUID
    ) async {
        do {
            _ = try await translateAndDeliver(
                inputText: inputText,
                transcript: record.transcript,
                configuration: configuration,
                runID: runID,
                recordReleaseToClipboard: false
            )
            finishRunSucceeded(runID)
        } catch {
            finishRunFailed(runID, error: error)
        }
    }
}
