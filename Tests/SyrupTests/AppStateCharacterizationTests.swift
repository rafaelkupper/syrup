import Foundation
import Observation
import Synchronization
import Testing
@testable import Syrup

// Behavior the AppState split must keep that the older suites did not pin. Written against the
// code before the split (2026-11-14) and kept as ordinary tests afterwards.

/// What the menu bar icon and the recording cue show. The cue spy here keeps every state it is
/// given, repeats and leading `.hidden` included, so a missing or extra update shows.
@MainActor
struct StatusDisplayCharacterizationTests {
    @Test func aSuccessfulRunAppliesEachCueStateInOrder() async {
        let cue = CueLog(), flash = ManualResetSleeper(), reset = ManualResetSleeper()
        let state = cueState(cue: cue, flash: flash, reset: reset)

        state.triggerPressed()
        state.triggerReleased()
        await flash.waitForCallCount(1)
        #expect(state.pipelineState == .idle)
        #expect(cue.states == [.hidden, .recording(caption: nil), .processing, .processing, .hidden, .success])

        await flash.resumeCall(0)
        await eventually { cue.states.count == 7 }
        #expect(cue.states.last == .hidden)
        #expect(state.menuBarSymbol == "waveform")
        await state.waitForPendingWork()
    }

    @Test func aCancelledRunAppliesHiddenOnce() async {
        let cue = CueLog(), flash = ManualResetSleeper(), reset = ManualResetSleeper()
        let state = cueState(cue: cue, transcriber: FakeTranscriber(.suspended), flash: flash, reset: reset)

        state.triggerPressed()
        state.cancelRequested()
        await state.waitForPendingWork()

        #expect(cue.states == [.hidden, .recording(caption: nil), .hidden])
        #expect(await flash.observedCallCount() == 0)
    }

    @Test func aFailedRunShowsItsErrorUntilTheResetClearsIt() async {
        let cue = CueLog(), flash = ManualResetSleeper(), reset = ManualResetSleeper()
        let state = cueState(cue: cue, transformer: FakeTextTransformer(.failure(.transformer)), flash: flash, reset: reset)

        state.triggerPressed()
        state.triggerReleased()
        await reset.waitForCallCount(1)
        #expect(state.pipelineState == .error("Something went wrong"))
        #expect(cue.states == [
            .hidden, .recording(caption: nil), .processing, .processing, .processing, .error("Something went wrong")
        ])
        #expect(state.menuBarSymbol == "exclamationmark.triangle")

        await reset.resumeCall(0)
        await eventually { state.pipelineState == .idle }
        #expect(cue.states.count == 7)
        #expect(cue.states.last == .hidden)
        #expect(await flash.observedCallCount() == 0)
        await state.waitForPendingWork()
    }

    @Test func copyLastFlashesSuccessThenHides() async {
        let cue = CueLog(), flash = ManualResetSleeper(), reset = ManualResetSleeper()
        let state = cueState(cue: cue, history: historyWithSuccess(), flash: flash, reset: reset)

        state.copyLastResult()
        #expect(cue.states == [.hidden, .success])
        #expect(state.menuBarSymbol == "checkmark.circle")

        await flash.waitForCallCount(1)
        await flash.resumeCall(0)
        await eventually { cue.states.count == 3 }
        #expect(cue.states == [.hidden, .success, .hidden])
        #expect(state.menuBarSymbol == "waveform")
    }

    @Test func aFailedCopyShowsItsErrorUntilTheResetClearsIt() async {
        let cue = CueLog(), flash = ManualResetSleeper(), reset = ManualResetSleeper()
        let state = cueState(cue: cue, history: historyWithSuccess(), pasteboard: FailingPasteboard(),
                             flash: flash, reset: reset)

        state.copyLastResult()
        #expect(cue.states == [.hidden, .error("Clipboard could not be written")])

        await reset.waitForCallCount(1)
        await reset.resumeCall(0)
        await eventually { state.pipelineState == .idle }
        #expect(cue.states == [.hidden, .error("Clipboard could not be written"), .hidden])
        #expect(await flash.observedCallCount() == 0)
    }

    @Test func aRunStartedDuringTheSuccessFlashEndsIt() async {
        let cue = CueLog(), flash = ManualResetSleeper(), reset = ManualResetSleeper()
        let state = cueState(cue: cue, history: historyWithSuccess(), transcriber: FakeTranscriber(.suspended),
                             flash: flash, reset: reset)

        state.copyLastResult()
        await flash.waitForCallCount(1)
        state.triggerPressed()
        #expect(state.menuBarSymbol == "waveform.badge.microphone")
        state.cancelRequested()

        #expect(cue.states == [.hidden, .success, .hidden, .recording(caption: nil), .hidden])
        #expect(state.menuBarSymbol == "waveform")
        await state.waitForPendingWork()
        await flash.resumeAll(throwing: CancellationError())
    }

    @Test func menuBarObserversHearTheSuccessFlashEnd() async {
        let flash = ManualResetSleeper()
        let state = characterizedState(history: historyWithSuccess(), feedbackFlashSleeper: { try await flash.sleep(nanoseconds: $0) })
        state.copyLastResult()
        await flash.waitForCallCount(1)
        #expect(state.menuBarSymbol == "checkmark.circle")

        let changed = ChangeFlag()
        withObservationTracking { _ = state.menuBarSymbol } onChange: { changed.set() }
        await flash.resumeCall(0)

        await eventually { state.menuBarSymbol == "waveform" }
        #expect(changed.isSet)
    }
}

/// Copy and Paste Last.
@MainActor
struct ResultActionsCharacterizationTests {
    @Test func aNewerPasteLastSupersedesOneStillWaiting() async {
        let clipboard = SpyPasteboard(), paster = SpyAutoPaster(), sleeper = ManualResetSleeper()
        let state = pastingState(clipboard: clipboard, paster: paster, sleeper: sleeper)

        let first = Task { await state.pasteLastResult() }
        await sleeper.waitForCallCount(1)
        let second = Task { await state.pasteLastResult() }
        await sleeper.waitForCallCount(2)

        await sleeper.resumeCall(0)
        await first.value
        #expect(paster.pasteCount == 0)

        await sleeper.resumeCall(1)
        await second.value
        #expect(paster.pasteCount == 1)
        #expect(clipboard.writes == ["previous", "previous"])
    }

    @Test func aRunThatStartsAndEndsWhilePasteLastWaitsCancelsIt() async {
        let clipboard = SpyPasteboard(), paster = SpyAutoPaster(), sleeper = ManualResetSleeper()
        let state = pastingState(clipboard: clipboard, paster: paster, sleeper: sleeper)

        let paste = Task { await state.pasteLastResult() }
        await sleeper.waitForCallCount(1)
        state.triggerPressed()
        state.cancelRequested()
        #expect(state.pipelineState == .idle)
        #expect(state.canCopyLastResult)

        await sleeper.resumeCall(0)
        await paste.value
        #expect(paster.pasteCount == 0)
        #expect(clipboard.writes == ["previous"])
        await state.waitForPendingWork()
    }

    @Test func copyResultAgainObserversHearAFailedClipboardWrite() async {
        let pasteboard = SpyPasteboard()
        pasteboard.failuresRemaining = 1
        let state = characterizedState(pasteboard: pasteboard)
        #expect(state.canCopyPendingResult == false)

        let changed = ChangeFlag()
        withObservationTracking { _ = state.canCopyPendingResult } onChange: { changed.set() }
        state.triggerPressed()
        state.triggerReleased()
        await settleRun(state)

        #expect(state.canCopyPendingResult)
        #expect(changed.isSet)
        state.copyPendingResult()
        #expect(pasteboard.writes == ["Good morning, how are you?"])
        #expect(state.canCopyPendingResult == false)
    }

    private func pastingState(clipboard: SpyPasteboard, paster: SpyAutoPaster, sleeper: ManualResetSleeper) -> AppState {
        let settings = makeTestSettings()
        settings.autoPasteEnabled = true
        return characterizedState(settings: settings, transcriber: FakeTranscriber(.suspended), pasteboard: clipboard,
                         history: historyWithSuccess(output: "previous"), autoPaster: paster,
                         autoPasteSleeper: { try await sleeper.sleep(nanoseconds: $0) })
    }
}

/// The output-volume chain.
@MainActor
struct OutputVolumeCharacterizationTests {
    private static let original: [UInt32: Float32] = [1: 0.8]

    @Test func crashRecoveryRestoresThroughTheChainThatPendingWorkAwaits() async throws {
        let volume = VolumeControllerFake(channels: Self.original)
        defer { volume.cleanUp() }
        try await volume.makeDucker().lower()
        #expect(volume.writes.count == 1)

        let state = AppState.fixture(settings: makeTestSettings(), outputDucker: volume.makeDucker())
        state.restoreOutputVolumeAfterCrash()
        await state.waitForPendingWork()

        #expect(volume.writes.count == 2)
        #expect(volume.writes.last == Self.original)
    }

    @Test func quittingWaitsForACancelledRunsVolumeRestore() async throws {
        let volume = VolumeControllerFake(channels: Self.original, holdsFirstWrite: true)
        defer { volume.cleanUp() }
        let settings = makeTestSettings()
        settings.lowerOtherAudioWhileRecording = true
        let recorder = FakeRecorder()
        let state = characterizedState(settings: settings, recorder: recorder, transcriber: FakeTranscriber(.suspended),
                              outputDucker: volume.makeDucker())
        state.triggerPressed()
        await eventually { recorder.startCallCount == 1 && volume.accessCount == 1 }

        let quit = QuitProbe(state)
        await eventually { state.pipelineState == .idle }
        try await Task.sleep(for: .milliseconds(100))
        #expect(quit.finished == false)
        #expect(volume.writes.isEmpty)

        volume.releaseFirstWrite()
        await quit.task.value
        #expect(volume.writes == [[1: 0.8 * 0.3], Self.original])
    }
}

/// Speech warm-up for the workflows a shortcut or app route can start.
@MainActor
struct SpeechReadinessCharacterizationTests {
    @Test func refreshingShortcutsWarmsTheActiveWorkflowsModelEachTime() {
        let models = FakeParakeetModels(.downloaded)
        let settings = makeTestSettings()
        settings.workflowList = WorkflowList(workflows: [Workflow(
            id: UUID(), name: "Dictate", kind: .transcribeOnly(cleanup: false), dictationLocaleID: "pt-BR",
            translationProvider: nil, speechEngine: .parakeetUltra
        )])
        let state = AppState.fixture(
            settings: settings, transcriberAssetManager: TranscriberAssetManager(prepare: { .installed($0) }),
            speechModels: [.parakeetUltra: InstalledSpeechModel(transcriber: FakeTranscriber(.success("x")), models: models)]
        )

        state.refreshWorkflowHotkeys()
        #expect(models.loadRequests == 1)
        state.refreshWorkflowHotkeys()
        #expect(models.loadRequests == 2)
    }

    @Test func anUnchangedSetOfBoundLocalesIsNotPreparedAgain() async throws {
        let probe = PreparedLocales()
        let manager = TranscriberAssetManager(prepare: { locale in
            await probe.record(locale)
            return .failed(locale)
        })
        let settings = makeTestSettings()
        let active = Workflow(id: UUID(), name: "Active", kind: .transcribeOnly(cleanup: false),
                              dictationLocaleID: "pt-BR", translationProvider: nil)
        let routed = Workflow(id: UUID(), name: "Routed", kind: .transcribeOnly(cleanup: false),
                              dictationLocaleID: "fr-FR", translationProvider: nil)
        settings.workflowList = WorkflowList(workflows: [active, routed])
        let state = AppState.fixture(settings: settings, transcriberAssetManager: manager)

        state.refreshWorkflowHotkeys()
        await eventually { manager.assetState(forLocale: "pt-BR") == .failed("pt-BR") }
        state.refreshWorkflowHotkeys()
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.locales == ["pt-BR"])

        settings.workflowList.routeApplication("test.app", to: routed.id)
        state.refreshWorkflowHotkeys()
        await eventually { await probe.locales.count == 3 }
        #expect(await probe.locales.sorted() == ["fr-FR", "pt-BR", "pt-BR"])
    }
}

// MARK: - Helpers

@MainActor
private final class CueLog: RecordingCuePresenting {
    private(set) var states: [RecordingCueState] = []
    func apply(_ state: RecordingCueState) { states.append(state) }
    func updateLevel(_ level: Double) {}
    func updateTranscript(_ text: String) {}
}

private final class ChangeFlag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

@MainActor
private final class QuitProbe {
    private(set) var finished = false
    private(set) var task: Task<Void, Never>!

    init(_ state: AppState) {
        task = Task { [weak self] in
            await state.prepareForTermination()
            self?.finished = true
        }
    }
}

private actor PreparedLocales {
    private(set) var locales: [String] = []
    func record(_ locale: String) { locales.append(locale) }
}

@MainActor
private func historyWithSuccess(output: String = "Earlier result") -> HistoryStore {
    let history = HistoryStore()
    history.append(successfulRecord(output: output))
    return history
}

@MainActor
private func cueState(
    cue: CueLog,
    history: HistoryStore = HistoryStore(),
    pasteboard: any PasteboardWriting = SpyPasteboard(),
    transcriber: any Transcriber = FakeTranscriber(.success("bom dia")),
    transformer: any TextTransformer = FakeTextTransformer(.success("Good morning")),
    flash: ManualResetSleeper,
    reset: ManualResetSleeper
) -> AppState {
    AppState.fixture(
        settings: makeTestSettings(),
        history: history,
        audioRecorder: FakeRecorder(),
        transcriber: transcriber,
        transformer: transformer,
        pasteboard: pasteboard,
        errorResetSleeper: { try await reset.sleep(nanoseconds: $0) },
        feedbackFlashSleeper: { try await flash.sleep(nanoseconds: $0) },
        maximumRecordingDurationNanoseconds: 0,
        recordingClock: FastForwardClock(),
        recordingCue: cue
    )
}

@MainActor
private func characterizedState(
    settings: AppSettings = makeTestSettings(),
    recorder: FakeRecorder = FakeRecorder(),
    transcriber: any Transcriber = FakeTranscriber(.success("bom dia, tudo bem?")),
    pasteboard: any PasteboardWriting = SpyPasteboard(),
    history: HistoryStore = HistoryStore(),
    autoPaster: any AutoPasting = SpyAutoPaster(),
    feedbackFlashSleeper: @escaping FeedbackFlashSleeper = { try await Task.sleep(nanoseconds: $0) },
    autoPasteSleeper: @escaping AutoPasteSleeper = { try await Task.sleep(nanoseconds: $0) },
    outputDucker: OutputDucker? = nil
) -> AppState {
    AppState.fixture(
        settings: settings,
        history: history,
        audioRecorder: recorder,
        transcriber: transcriber,
        transformer: FakeTextTransformer(.success("Good morning, how are you?")),
        pasteboard: pasteboard,
        autoPaster: autoPaster,
        feedbackFlashSleeper: feedbackFlashSleeper,
        maximumRecordingDurationNanoseconds: 0,
        autoPasteDelayNanoseconds: 0,
        autoPasteSleeper: autoPasteSleeper,
        recordingClock: FastForwardClock(),
        outputDucker: outputDucker,
        captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) }
    )
}
