import AVFoundation
import Foundation
import Testing
@testable import Syrup

// Helpers shared by the AppState test files.

@MainActor
func verifyFailedVoiceContextMiss(
    capture: SelectionCapture,
    expectedNotification: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let settings = makeTestSettings()
    let replyDraft = try #require(
        WorkflowTemplate.templates().first { $0.id == "reply-draft" },
        sourceLocation: sourceLocation
    )
    settings.addWorkflow(from: replyDraft)
    let pasteboard = SpyPasteboard()
    let feedback = SpyFeedback()
    let history = HistoryStore()
    let state = makeState(
        settings: settings,
        transformer: FakeTextTransformer(.failure(.transformer)),
        pasteboard: pasteboard,
        feedback: feedback,
        history: history,
        selectionReader: FakeSelectionReader(capture)
    )

    state.triggerPressed()
    state.triggerReleased()
    await expectState(
        state,
        .error("Something went wrong"),
        sourceLocation: sourceLocation
    )

    let record = try #require(history.records.first, sourceLocation: sourceLocation)
    guard case .custom(let base, let enforcesOutputContract) = replyDraft.kind else {
        Issue.record("Reply Draft is a custom workflow", sourceLocation: sourceLocation)
        return
    }
    #expect(record.transformation == .custom(
        workflowName: "Reply Draft",
        instruction: PromptBuilder.instruction(for: replyDraft.kind),
        prompt: .init(base: base, enforcesOutputContract: enforcesOutputContract)
    ), sourceLocation: sourceLocation)
    #expect(record.canUseTranscriptFallback, sourceLocation: sourceLocation)
    #expect(record.canRetry, sourceLocation: sourceLocation)
    #expect(record.canCopyFromHistory, sourceLocation: sourceLocation)
    #expect(
        state.transcriptFallback == "bom dia, tudo bem?",
        sourceLocation: sourceLocation
    )
    #expect(feedback.errorMessages == [expectedNotification], sourceLocation: sourceLocation)
    #expect(
        feedback.transformationFailures.map(\.allowsTranscriptFallback) == [true],
        sourceLocation: sourceLocation
    )
    #expect(
        feedback.transformationFailures.map(\.allowsRetry) == [true],
        sourceLocation: sourceLocation
    )
    #expect(pasteboard.writes.isEmpty, sourceLocation: sourceLocation)
}

@MainActor
func makeState(
    settings: AppSettings? = nil,
    recorder: FakeRecorder = FakeRecorder(),
    transcriber: any Transcriber = FakeTranscriber(.success("bom dia, tudo bem?")),
    transformer: any TextTransformer = FakeTextTransformer(.success("Good morning, how are you?")),
    transformerProvider: (any TransformerSnapshotting)? = nil,
    pasteboard: any PasteboardWriting = SpyPasteboard(),
    feedback: any AppFeedbackProviding = SpyFeedback(),
    metrics: any PipelineMetricsRecording = PipelineMetricsRecorder(),
    history: HistoryStore = HistoryStore(),
    autoPaster: any AutoPasting = SpyAutoPaster(),
    streamingTypistFactory: @escaping () -> any StreamingTyping = { StreamingTypist() },
    errorResetDelayNanoseconds: UInt64 = 4_000_000_000,
    errorResetSleeper: @escaping ErrorResetSleeper = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    },
    feedbackFlashDurationNanoseconds: UInt64 = 1_000_000_000,
    feedbackFlashSleeper: @escaping FeedbackFlashSleeper = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    },
    maximumRecordingDurationNanoseconds: UInt64? = 0,
    recordingDurationSleeper: @escaping RecordingDurationSleeper = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    },
    autoPasteDelayNanoseconds: UInt64 = 0,
    autoPasteSleeper: @escaping AutoPasteSleeper = { nanoseconds in
        try await Task.sleep(nanoseconds: nanoseconds)
    },
    recordingClock: any RecordingClock = FastForwardClock(),
    installHotkeys: Bool = false,
    selectionReader: any SelectionReading = FakeSelectionReader(.empty),
    recordingArchive: (any RecordingArchiving)? = nil,
    captureDeliveryTarget: @escaping @MainActor (pid_t?) async -> DeliveryTarget? = { _ in DeliveryTarget(checkCurrent: { true }) }
) -> AppState {
    AppState.fixture(
        settings: settings ?? makeTestSettings(),
        history: history,
        audioRecorder: recorder,
        transcriber: transcriber,
        transformer: transformer,
        transformerProvider: transformerProvider,
        pasteboard: pasteboard,
        feedback: feedback,
        metrics: metrics,
        autoPaster: autoPaster,
        streamingTypistFactory: streamingTypistFactory,
        errorResetDelayNanoseconds: errorResetDelayNanoseconds,
        errorResetSleeper: errorResetSleeper,
        feedbackFlashDurationNanoseconds: feedbackFlashDurationNanoseconds,
        feedbackFlashSleeper: feedbackFlashSleeper,
        maximumRecordingDurationNanoseconds: maximumRecordingDurationNanoseconds,
        recordingDurationSleeper: recordingDurationSleeper,
        autoPasteDelayNanoseconds: autoPasteDelayNanoseconds,
        autoPasteSleeper: autoPasteSleeper,
        recordingClock: recordingClock,
        installHotkeys: installHotkeys,
        selectionReader: selectionReader,
        recordingArchive: recordingArchive,
        captureDeliveryTarget: captureDeliveryTarget
    )
}

func temporaryKeychainStore() -> (KeychainStore, URL) {
    let storageDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(testDomainName("SyrupAppStateTests"), isDirectory: true)
    let store = KeychainStore(
        service: "org.syrup.SyrupAppStateTests",
        storageDirectory: storageDirectory
    )
    return (store, storageDirectory)
}

func successfulRecord(output: String) -> DictationRecord {
    DictationRecord(
        id: UUID(),
        finishedAt: Date.now,
        transcript: "Original dictation",
        output: output,
        transformation: .translation(targetLanguage: "English", toneInstruction: ""),
        outcome: .success
    )
}

/// A real error state: Copy Last fails on a clipboard that refuses writes.
@MainActor
func stateShowingAnError() -> AppState {
    let history = HistoryStore()
    history.append(successfulRecord(output: "Earlier result"))
    let state = makeState(pasteboard: FailingPasteboard(), history: history)
    state.copyLastResult()
    precondition(state.pipelineState == .error("Clipboard could not be written"))
    return state
}

@MainActor
func makeTestSettings() -> AppSettings {
    let suiteName = testDomainName("SyrupAppStateTests")
    guard let userDefaults = UserDefaults(suiteName: suiteName) else {
        preconditionFailure("Unable to create isolated AppState test defaults")
    }
    userDefaults.removePersistentDomain(forName: suiteName)
    return AppSettings(
        userDefaults: userDefaults,
        defaultMicrophoneIDProvider: { "" }
    )
}

@MainActor
func expectState(
    _ state: AppState,
    _ expectedState: AppState.PipelineState,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { state.pipelineState == expectedState }) { return }

    #expect(state.pipelineState == expectedState, sourceLocation: sourceLocation)
}

@MainActor
func expectPasteboardWrites(
    _ pasteboard: SpyPasteboard,
    _ expectedWrites: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { pasteboard.writes == expectedWrites }) { return }

    #expect(pasteboard.writes == expectedWrites, sourceLocation: sourceLocation)
}

@MainActor
func expectRecorderStartCount(
    _ recorder: FakeRecorder,
    _ expectedCount: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { recorder.startCallCount == expectedCount }) { return }

    #expect(recorder.startCallCount == expectedCount, sourceLocation: sourceLocation)
}

@MainActor
func expectHistoryCount(
    _ history: HistoryStore,
    _ expectedCount: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { history.records.count == expectedCount }) { return }

    #expect(history.records.count == expectedCount, sourceLocation: sourceLocation)
}

@MainActor
func expectArchiveDiscardCount(
    _ archive: SpyRecordingArchive,
    _ expectedCount: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { await archive.snapshot().discardedEntryIDs.count == expectedCount }) { return }

    #expect(
        await archive.snapshot().discardedEntryIDs.count == expectedCount,
        sourceLocation: sourceLocation
    )
}

@MainActor
func expectAutoPasteCompleted(
    _ autoPaster: SpyAutoPaster,
    metrics: SpyPipelineMetrics,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, {
        autoPaster.pasteCount == 1
            && metrics.begunStages.contains(.autoPaste)
            && metrics.endedStages.contains(.autoPaste)
    }) { return }

    #expect(autoPaster.pasteCount == 1, sourceLocation: sourceLocation)
    #expect(metrics.begunStages.contains(.autoPaste), sourceLocation: sourceLocation)
    #expect(metrics.endedStages.contains(.autoPaste), sourceLocation: sourceLocation)
}

@MainActor
func expectStreamingTypistStartCount(
    _ typist: SpyStreamingTypist,
    _ expectedCount: Int,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { typist.startCount == expectedCount }) { return }

    #expect(typist.startCount == expectedCount, sourceLocation: sourceLocation)
}

@MainActor
func expectMenuBarSymbol(
    _ state: AppState,
    _ expectedSymbol: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    if await eventually(sourceLocation: sourceLocation, { state.menuBarSymbol == expectedSymbol }) { return }

    #expect(state.menuBarSymbol == expectedSymbol, sourceLocation: sourceLocation)
}
