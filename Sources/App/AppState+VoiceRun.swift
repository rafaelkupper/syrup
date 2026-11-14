import AVFoundation
import Foundation

/// Child tasks one voice run starts. They are cancelled together when the run ends, however it ends,
/// except work handed on to file the recording after a successful delivery.
@MainActor
final class VoiceRunWork {
    var transcription: Task<String, any Error>?
    var appleTranscription: Task<String, any Error>?
    var transformer: Task<any TextTransformer, Never>?
    var provisionalRecordingID: UUID?
    var recordingTee: RecordingTeeSession?

    func cancel() {
        transcription?.cancel()
        appleTranscription?.cancel()
        transformer?.cancel()
    }
}

/// A finished transcript: `raw` as the engine returned it, trimmed, for usage counts and the learning
/// archive; `text` after the workflow's corrections, which the rest of the run uses.
struct VoiceTranscript {
    let raw: String
    let text: String
}

/// The voice run, in phases: open the microphone, wait for the run's configuration, transcribe until
/// the stop, then transform and deliver (`AppState+Delivery.swift`), then file the recording.
extension AppState {
    func runPipeline(runID: UUID, resolvedConfiguration: Task<RunConfiguration?, Never>) async {
        let work = VoiceRunWork()
        defer {
            resolvedConfiguration.cancel()
            work.cancel()
        }

        do {
            guard let run = activeRun, run.id == runID else { return }
            let audio = try await openMicrophone(for: run, work: work)
            let configuration = try await awaitConfiguration(resolvedConfiguration, for: run)
            work.transformer = run.preparedTransformer
            run.transformationInstruction = configuration.instruction
            startTranscription(of: audio, configuration: configuration, run: run, work: work)
            let transcript = try await finishTranscription(configuration: configuration, run: run, work: work)
            try await deliverTranscript(transcript, configuration: configuration, run: run, work: work)
            work.transformer = nil
            recordUsage(rawTranscript: transcript.raw, transcript: transcript.text, configuration: configuration, run: run)
            fileRecording(rawTranscript: transcript.raw, configuration: configuration, work: work)
            if run.lowersOtherAudio, let outputVolumeWork {
                _ = try? await withOperationTimeout(.seconds(1), error: CancellationError()) {
                    await outputVolumeWork.value
                }
            }
            finishRunSucceeded(runID)
        } catch {
            if isCurrentRun(runID) {
                audioRecorder.stop()
            }
            await work.recordingTee?.cancelAndWait()
            if let provisionalRecordingID = work.provisionalRecordingID {
                await recordingArchive?.discardEntry(id: provisionalRecordingID)
            }
            finishRunFailed(runID, error: error)
        }
    }

    // MARK: - Recording and transcription

    /// Starts capture and wraps the stream with the level tap, the pause-transformation copy, and the
    /// opt-in learning archive. Returns once audio is flowing.
    private func openMicrophone(for run: PipelineRun, work: VoiceRunWork) async throws -> AudioBufferSequence {
        let runID = run.id
        try Task.checkCancellation()
        if let failure = run.failure { throw failure }

        audioRecorder.onFailure = { [weak self] error in
            self?.recordingFailed(error, runID: runID)
        }
        let rawAudio = try await audioRecorder.start()
        let levelCue = run.showRecordingCue ? recordingCue : nil
        var audio = AudioLevelTap.attach(to: rawAudio, onOverflow: { [weak self] in
            Task { @MainActor in self?.recordingFailed(AudioRecordingError.audioBufferOverflow, runID: runID) }
        }) { [weak self, weak levelCue] level in
            Task { @MainActor in
                guard self?.isCurrentRun(runID) == true else { return }
                levelCue?.updateLevel(level.smoothed)
                self?.receiveBufferLevel(dBFS: level.dBFS, runID: runID)
            }
        }
        if let capture = run.pauseAudio {
            audio = capture.attach(to: audio) { [weak run] in
                run?.pauseCheckTask?.cancel()
                run?.pauseCheckTask = nil
            }
        }
        if run.learnsFromRecording, settings.glossaryLearningEnabled, let recordingArchive {
            do {
                let fileURL = try await recordingArchive.beginEntry(id: runID)
                work.provisionalRecordingID = runID
                let session = RecordingTee.attach(to: audio, fileURL: fileURL, onOverflow: { [weak self] in
                    Task { @MainActor in self?.recordingFailed(AudioRecordingError.audioBufferOverflow, runID: runID) }
                })
                work.recordingTee = session
                audio = session.stream
            } catch {
                // Archiving is best-effort and must never fail a dictation. A pending cleanup
                // also refuses new entries here, so retention caps stay enforceable.
            }
        }
        guard isCurrentRun(runID) else {
            throw CancellationError()
        }
        metrics.end(.hotkeyToRecordingStarted, runID: runID)
        if run.lowersOtherAudio {
            changeOutputVolume { try await $0.lower() }
        }
        try Task.checkCancellation()
        return audio
    }

    /// Audio is already buffering. The selection and editor reads finish here, before the instruction
    /// is used by transcription vocabulary or an early transformation.
    private func awaitConfiguration(
        _ resolvedConfiguration: Task<RunConfiguration?, Never>, for run: PipelineRun
    ) async throws -> RunConfiguration {
        let resolved = await withTaskCancellationHandler {
            await resolvedConfiguration.value
        } onCancel: {
            resolvedConfiguration.cancel()
        }
        guard let configuration = resolved, isCurrentRun(run.id) else { throw CancellationError() }
        try Task.checkCancellation()
        return configuration
    }

    /// Starts transcription beside capture. With a ready downloadable model, Apple gets one copy of the
    /// audio for the preview and the model the other for the delivered text, falling back to Apple.
    private func startTranscription(
        of audio: AudioBufferSequence, configuration: RunConfiguration, run: PipelineRun, work: VoiceRunWork
    ) {
        let runID = run.id
        let transcriber = transcriber
        let locale = Locale(identifier: configuration.dictationLocaleID)
        metrics.begin(.transcriptionWindow, runID: runID)
        var onPartialTranscript: (@Sendable (String) -> Void)?
        if recordingCue != nil && run.showRecordingCue && run.showLiveTranscript {
            onPartialTranscript = { [weak self] text in
                Task { @MainActor in
                    guard let self, self.isCurrentRun(runID) else { return }
                    if run.showRecordingCue && run.showLiveTranscript {
                        self.recordingCue?.updateTranscript(text)
                    }
                }
            }
        }
        guard let modelTranscriber = run.speechModel.transcriber else {
            let preferFastResults = run.preferFastTranscription
            work.transcription = Task {
                do {
                    return try await transcriber.transcribe(audio, request: TranscriptionRequest(
                        locale: locale, vocabulary: configuration.speechVocabulary,
                        onPartialTranscript: onPartialTranscript, preferFastResults: preferFastResults
                    ))
                } catch {
                    recordingFailed(error, runID: runID)
                    throw error
                }
            }
            return
        }

        let (previewAudio, finalAudio) = AudioFanOut.split(audio)
        let streams = configuration.speechEngine.isStreaming
        let preview = Task {
            try await transcriber.transcribe(previewAudio, request: TranscriptionRequest(
                locale: locale, vocabulary: configuration.speechVocabulary,
                onPartialTranscript: streams ? nil : onPartialTranscript, preferFastResults: true
            ))
        }
        work.appleTranscription = preview
        work.transcription = Task {
            let modelText: String?
            do {
                modelText = try await modelTranscriber.transcribe(finalAudio, request: TranscriptionRequest(
                    locale: locale, vocabulary: configuration.speechVocabulary,
                    onPartialTranscript: streams ? onPartialTranscript : nil
                ))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                modelText = nil
            }
            if let modelText, modelText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                return modelText
            }
            do {
                return try await withTaskCancellationHandler {
                    try await preview.value
                } onCancel: {
                    preview.cancel()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch _ where modelText != nil {
                return ""
            } catch {
                recordingFailed(error, runID: runID)
                throw error
            }
        }
    }

    /// Waits for the stop, closes the microphone, and returns the corrected transcript.
    private func finishTranscription(
        configuration: RunConfiguration, run: PipelineRun, work: VoiceRunWork
    ) async throws -> VoiceTranscript {
        let runID = run.id
        try Task.checkCancellation()

        await waitForStopRecording()
        guard isCurrentRun(runID) else { throw CancellationError() }
        try Task.checkCancellation()

        if let failure = run.failure { throw failure }
        try await audioRecorder.finish()
        guard isCurrentRun(runID) else { throw CancellationError() }
        metrics.end(.releaseToRecorderStopped, runID: runID)
        if run.lowersOtherAudio {
            changeOutputVolume { try await $0.restore() }
        }
        enterProcessing(.transcribing)

        guard let activeTranscriptionTask = work.transcription else {
            throw CancellationError()
        }
        let transcript = try await withTaskCancellationHandler {
            try await activeTranscriptionTask.value
        } onCancel: {
            activeTranscriptionTask.cancel()
        }
        metrics.end(.transcriptionWindow, runID: runID)
        metrics.end(.releaseToTranscript, runID: runID)
        work.transcription = nil
        if work.provisionalRecordingID == nil {
            work.appleTranscription?.cancel()
            work.appleTranscription = nil
        }
        guard isCurrentRun(runID) else { throw CancellationError() }
        try Task.checkCancellation()

        if let failure = run.failure { throw failure }
        let text = PauseTransformation.input(transcript, corrections: configuration.corrections)
        guard text.isEmpty == false else {
            throw PipelineError.emptyTranscript
        }
        if let notice = run.speechModel.fallbackNotice, didNotifySpeechEngineFallback == false {
            didNotifySpeechEngineFallback = true
            feedback.notifyError(message: notice)
        }
        return VoiceTranscript(raw: transcript.trimmingCharacters(in: .whitespacesAndNewlines), text: text)
    }

    // MARK: - Transformation and delivery

    /// Cleans a Transcribe run locally, or transforms the transcript (or, for a revision, the captured
    /// earlier result), using an early result from a pause when it matches, then delivers.
    private func deliverTranscript(
        _ transcript: VoiceTranscript, configuration: RunConfiguration, run: PipelineRun, work: VoiceRunWork
    ) async throws {
        let runID = run.id
        if case .transcribeOnly(let cleanup, let symbols) = configuration.purpose {
            let output = TranscriptCleanup.apply(transcript.text, localeID: configuration.dictationLocaleID,
                                                 cleanup: cleanup, spokenSymbols: symbols)
            guard output.isEmpty == false else { throw PipelineError.emptyTranscript }
            try Task.checkCancellation()
            _ = try await commitAtomicOutput(output, transcript: transcript.text, configuration: configuration,
                                             runID: runID, recordReleaseToClipboard: true)
            return
        }

        let transformationInput: String
        let resolvedConfiguration: RunConfiguration
        switch configuration.purpose {
        case .revision(let base):
            transformationInput = base
            resolvedConfiguration = RunConfigurationBuilder.revision(
                configuration, adjustment: transcript.text, glossaryBlock: run.glossaryBlock
            )
        case .dictation, .transcribeOnly:
            transformationInput = transcript.text
            resolvedConfiguration = configuration
        }

        enterProcessing(.translating)
        if let earlyOutput = try await pauseTransformationOutput(for: transformationInput, run: run) {
            _ = try await commitAtomicOutput(earlyOutput, transcript: transcript.text,
                configuration: resolvedConfiguration, runID: runID, recordReleaseToClipboard: true)
        } else {
            _ = try await translateAndDeliver(
                inputText: transformationInput,
                transcript: transcript.text,
                configuration: resolvedConfiguration,
                runID: runID,
                preparedTransformerTask: work.transformer,
                recordReleaseToClipboard: true
            )
        }
    }

    // MARK: - After delivery

    /// Hands an opted-in recording to the archive. It is committed once the WAV is complete and Apple's
    /// transcript of the same audio is known, without holding up the run.
    private func fileRecording(rawTranscript: String, configuration: RunConfiguration, work: VoiceRunWork) {
        defer { work.provisionalRecordingID = nil }
        guard let recordingID = work.provisionalRecordingID, let recordingArchive else { return }
        let tee = work.recordingTee
        let appleTranscription = work.appleTranscription
        work.appleTranscription = nil
        recordingWork[recordingID] = Task { [weak self, settings] in
            defer { self?.recordingWork[recordingID] = nil }
            let archived = await tee?.waitForCompletion() ?? false
            let appleTranscript = if let appleTranscription {
                ((try? await appleTranscription.value) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                rawTranscript
            }
            // An opt-out made while this recording was filed wins over the run's frozen opt-in.
            if archived, settings.glossaryLearningEnabled, appleTranscript.isEmpty == false {
                await recordingArchive.commitEntry(id: recordingID, localeID: configuration.dictationLocaleID, appleTranscript: appleTranscript)
            } else {
                await recordingArchive.discardEntry(id: recordingID)
            }
        }
    }

    /// Counts only. The transcript is measured here and goes no further.
    private func recordUsage(rawTranscript: String, transcript: String, configuration: RunConfiguration, run: PipelineRun) {
        guard run.keepsUsageStats, settings.keepsUsageStats else { return }
        var fixes = Correction.replacementCount(configuration.corrections, in: rawTranscript)
        switch configuration.purpose {
        case .revision:
            return
        case .transcribeOnly(let cleanup, _):
            if cleanup {
                fixes += TranscriptCleanup.fillerCount(in: transcript, localeID: configuration.dictationLocaleID)
            }
        case .dictation:
            break
        }
        let recorded = run.voicedDuration > .zero
            ? run.voicedDuration
            : run.releasedAt.map { run.triggeredAt.duration(to: $0) } ?? .zero
        let parts = recorded.components
        let frontmost = frontmostApplication(true).bundleID
        usageStats.record(
            words: UsageStats.wordCount(in: transcript),
            seconds: Double(parts.seconds) + Double(parts.attoseconds) / 1e18,
            fixes: fixes,
            appBundleID: frontmost == Bundle.main.bundleIdentifier ? nil : frontmost
        )
    }

    // MARK: - Recording control

    func recordingFailed(_ error: any Error, runID: UUID) {
        guard let run = activeRun, run.id == runID, run.deliveryCommitted == false else { return }
        if run.failure == nil { run.failure = error }
        run.cancelPauseTransformation()
        if pipelineState == .recording {
            audioRecorder.stop()
            requestStopRecording(.failure)
        }
    }

    private func waitForStopRecording() async {
        await withCheckedContinuation { continuation in
            if activeRun?.recordingPhase == .stopping {
                continuation.resume()
            } else {
                activeRun?.stopWaiter = continuation
            }
        }
    }

    func requestStopRecording(_ reason: RunStopReason) {
        guard let run = activeRun else { return }

        switch (run.recordingPhase, reason) {
        case (.capturing, .hotkey) where run.hotkeyMode == .hold
            && run.triggeredAt.duration(to: recordingClock.now) < Self.minimumHold:
            cancelRequested()
        case (.capturing, _):
            metrics.begin(.releaseToRecorderStopped, runID: run.id)
            metrics.begin(.releaseToTranscript, runID: run.id)
            metrics.begin(.releaseToClipboard, runID: run.id)
            run.releasedAt = recordingClock.now
            run.stopPauseTranscription()
            metrics.recordQuietBeforeRelease(run.lastLoudAt.duration(to: recordingClock.now), runID: run.id)
            if reason == .hotkey, run.lastBufferWasQuiet == false {
                run.recordingPhase = .releaseTail
                scheduleReleaseTailDeadline(for: run)
            } else {
                stopRecording(run)
            }
        case (.releaseTail, .failure):
            stopRecording(run)
        case (.releaseTail, _), (.stopping, _):
            break
        }
    }

    private func scheduleReleaseTailDeadline(for run: PipelineRun) {
        let runID = run.id
        let clock = recordingClock
        let deadline = clock.now + ReleaseTail.deadline
        run.releaseTailDeadline = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }

            self?.receiveReleaseTail(.deadlineReached, runID: runID)
        }
    }

    private func receiveBufferLevel(dBFS: Double, runID: UUID) {
        guard let run = activeRun, run.id == runID else { return }
        run.lastBufferWasQuiet = ReleaseTail.decision(after: .bufferLevel(dBFS: dBFS)) == .finish
        let now = recordingClock.now
        if let last = run.lastLevelAt, run.lastBufferWasQuiet == false {
            run.voicedDuration += last.duration(to: now)
        }
        run.lastLevelAt = now
        if run.recordingPhase == .capturing {
            if run.lastBufferWasQuiet {
                if run.quietSince == nil { run.quietSince = now }
                schedulePauseTransformation(for: run)
            } else {
                run.lastLoudAt = now
                run.quietSince = nil
                run.pauseCheckedQuiet = false
                run.pauseCheckTask?.cancel()
                run.pauseCheckTask = nil
            }
        }
        receiveReleaseTail(.bufferLevel(dBFS: dBFS), runID: runID)
        metrics.recordBufferLevel(runID: runID)
    }

    private func schedulePauseTransformation(for run: PipelineRun) {
        guard run.pauseTransformationEligible, run.recordingPhase == .capturing,
              run.failure == nil, run.pauseCheckTask == nil, !run.pauseCheckedQuiet,
              let capture = run.pauseAudio, capture.isCapturing,
              let quietSince = run.quietSince else { return }
        let clock = recordingClock
        let transcriber = transcriber
        run.pauseCheckTask = Task { [weak self, weak run] in
            do {
                try await clock.sleep(until: quietSince + PauseTransformation.quietDuration)
                try Task.checkCancellation()
                guard let self, let run else { return }
                guard self.isCurrentRun(run.id), run.recordingPhase == .capturing,
                      run.failure == nil, let audio = capture.snapshot() else {
                    run.pauseCheckTask = nil
                    return
                }
                run.pauseCheckedQuiet = true
                let transcript = try await transcriber.transcribe(audio, request: TranscriptionRequest(
                    locale: Locale(identifier: run.configuration.dictationLocaleID),
                    vocabulary: run.configuration.speechVocabulary,
                    preferFastResults: run.preferFastTranscription
                ))
                try Task.checkCancellation()
                guard self.isCurrentRun(run.id), run.recordingPhase == .capturing,
                      run.failure == nil, capture.isCapturing else { return }
                run.pauseCheckTask = nil
                let input = PauseTransformation.input(transcript, corrections: run.configuration.corrections)
                guard !input.isEmpty, let snapshot = run.providerSnapshot else { return }
                if let previous = run.pauseAttempt, PauseTransformation.attemptMatches(
                    (previous.input, previous.instruction), input: input, instruction: run.transformationInstruction
                ) { return }
                run.pauseAttempt?.task.cancel()
                run.pauseAttemptCount += 1
                run.pauseAttempt = PauseTransformationAttempt(input: input, instruction: run.transformationInstruction,
                    provider: run.configuration.provider, snapshot: snapshot, clock: clock)
            } catch {
                if !Task.isCancelled { run?.pauseCheckTask = nil }
            }
        }
    }

    private func pauseTransformationOutput(for input: String, run: PipelineRun) async throws -> String? {
        guard run.pauseTransformationEligible else { return nil }
        guard let attempt = run.pauseAttempt else {
            run.pauseOutcome = PauseTransformationOutcome.none
            return nil
        }
        guard PauseTransformation.attemptMatches(
            (attempt.input, attempt.instruction), input: input, instruction: run.transformationInstruction
        ) else {
            attempt.task.cancel()
            run.pauseOutcome = .miss
            return nil
        }
        let output = await withTaskCancellationHandler {
            await attempt.task.value
        } onCancel: {
            attempt.task.cancel()
        }
        guard isCurrentRun(run.id) else { throw CancellationError() }
        try Task.checkCancellation()
        run.pauseOutcome = output == nil ? .failed : .hit
        if let output { metrics.recordDuration(.translation, duration: output.duration, runID: run.id) }
        return output?.text
    }

    private func receiveReleaseTail(_ event: ReleaseTail.Event, runID: UUID) {
        guard let run = activeRun, run.id == runID, run.recordingPhase == .releaseTail,
              ReleaseTail.decision(after: event) == .finish else { return }

        stopRecording(run)
    }

    func stopRecording(_ run: PipelineRun) {
        run.recordingPhase = .stopping
        run.releaseTailDeadline?.cancel()
        run.resumeStopWaiter()
    }

    func scheduleRecordingDurationLimit(for runID: UUID) {
        activeRun?.recordingDurationTask?.cancel()

        let duration = maximumRecordingDurationNanoseconds ?? settings.maximumRecordingDurationNanoseconds
        guard duration > 0 else { return }

        let sleeper = recordingDurationSleeper
        activeRun?.recordingDurationTask = Task { [weak self] in
            do {
                try await sleeper(duration)
            } catch {
                return
            }

            self?.stopRecordingIfDurationExceeded(runID: runID)
        }
    }

    private func stopRecordingIfDurationExceeded(runID: UUID) {
        guard activeRunID == runID, pipelineState == .recording,
              activeRun?.recordingPhase == .capturing else { return }

        requestStopRecording(.durationLimit)
        let duration = maximumRecordingDurationNanoseconds ?? settings.maximumRecordingDurationNanoseconds
        feedback.notifyRecordingAutoStopped(afterSeconds: Int(duration / 1_000_000_000))
    }

    func resumeStopWaiter() {
        let continuation = activeRun?.stopWaiter
        activeRun?.stopWaiter = nil
        continuation?.resume()
    }
}
