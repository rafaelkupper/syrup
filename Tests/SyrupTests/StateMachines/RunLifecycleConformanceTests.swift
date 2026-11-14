import AVFoundation
import Foundation
import KeyboardShortcuts
import Testing
@testable import Syrup

/// Replays `RunLifecycleModel` against the real `AppState`: walks that take every transition of the
/// model, performed on an `AppState` whose transcriber, provider, timers, clock, and microphone the
/// test controls. After every step the observable state of the real app must match the model's,
/// including which work is still in flight, so the model cannot drift from the code unnoticed.
@MainActor
@Suite(.serialized)
struct RunLifecycleConformanceTests {
    @Test(arguments: RunLifecycleModelTests.configurations)
    func theRealAppStateTakesEveryTransitionAsTheModelDoes(model: RunLifecycleModel) async {
        let checker = ModelChecker(model)
        let tour = ConformanceCoverage.tour(for: checker)
        let clock = ContinuousClock()
        let started = clock.now
        var steps = 0
        for (walkNumber, walk) in tour.enumerated() {
            var current = checker.states[walk.start]
            let harness = RunLifecycleHarness(model: model, hasResult: current.hasResult)
            defer { harness.tearDown() }
            if let mismatch = await harness.settle(expecting: harness.expectedObservation(of: current)) {
                Issue.record("Walk \(walkNumber) starts out of step with the model:\n\(mismatch)")
                return
            }
            for (index, step) in walk.steps.enumerated() {
                guard let result = model.step(current, step.action) else {
                    Issue.record("The tour took an action the model refuses: \(step.action)")
                    return
                }
                let (next, effects) = result
                harness.expectedEffects.add(effects)
                harness.perform(step.action)
                steps += 1
                if let mismatch = await harness.settle(expecting: harness.expectedObservation(of: next)) {
                    Issue.record(Comment(rawValue: """
                        The real AppState left the model at walk \(walkNumber), step \(index) (\(model.testDescription)).
                        Shortest path to the state before the step:
                          \(checker.describeTrace(to: checker.indexOf(current)!))
                        Step: \(step.action)
                        \(mismatch)
                        """))
                    return
                }
                current = next
            }
            await harness.finish()
        }
        print("RunLifecycleConformance \(model.testDescription): \(steps) steps in \(tour.count) walks, \(started.duration(to: clock.now))")
    }
}

extension ModelChecker {
    func indexOf(_ state: State) -> Int? {
        states.firstIndex(of: state)
    }
}

/// How much of a model the conformance replays cover. Every reachable state by default; every
/// transition with `TEST_RUNNER_SYRUP_FULL_CONFORMANCE=1`, which takes a few minutes.
enum ConformanceCoverage {
    static func tour<Model>(for checker: ModelChecker<Model>) -> [(start: Int, steps: [(action: Model.Action, target: Int)])] {
        ProcessInfo.processInfo.environment["SYRUP_FULL_CONFORMANCE"] == "1"
            ? checker.tour(covering: .transitions) : checker.tour(covering: .states)
    }
}

// MARK: - The harness

/// What the test can see of the real app, in the model's terms.
struct RunObservation: Equatable, CustomStringConvertible {
    struct RunView: Equatable {
        var isRevision: Bool
        var fromWorkflowShortcut: Bool
        var phase: PipelineRun.RecordingPhase
        var committed: Bool
        var failed: Bool
        var lastBufferQuiet: Bool
    }

    var pipeline: PipelineState
    var run: RunView?
    var hasResult: Bool
    var hasPendingResult: Bool
    var paused: Bool
    var flash: Bool
    var escapeEnabled: Bool
    var transcriptionsInFlight: Int
    var transformsInFlight: Int
    var flashTimers: Int
    var errorResetTimers: Int
    var durationTimers: Int
    var pasteDelays: Int
    var tailDeadlines: Int
    var bufferLevelsHandled: Int
    var effects: RunLifecycleModel.Effects

    var description: String {
        Mirror(reflecting: self).children.map { "\($0.label ?? "?"): \($0.value)" }.joined(separator: "\n    ")
    }

    func differences(from other: RunObservation) -> String {
        let mine = Mirror(reflecting: self).children.map { ($0.label ?? "?", "\($0.value)") }
        let theirs = Mirror(reflecting: other).children.map { "\($0.value)" }
        return zip(mine, theirs).filter { $0.0.1 != $0.1 }
            .map { "    \($0.0.0): model \($0.0.1), app \($0.1)" }.joined(separator: "\n")
    }
}

extension RunLifecycleModel.Effects {
    mutating func add(_ other: Self) {
        clipboardWrites += other.clipboardWrites
        successRecords += other.successRecords
        failedRecords += other.failedRecords
        pastes += other.pastes
        errorsShown += other.errorsShown
        autoStopNotices += other.autoStopNotices
        flashesStarted += other.flashesStarted
    }
}

@MainActor
final class RunLifecycleHarness {
    let model: RunLifecycleModel
    let state: AppState
    let settings: AppSettings
    let recorder = ConformanceRecorder()
    let transcriber = GatedTranscriber()
    let transformer = GatedTransformer()
    let timers = ManualTimers()
    let clock = ConformanceClock()
    let pasteboard = SpyPasteboard()
    let feedback = SpyFeedback()
    let metrics = SpyPipelineMetrics()
    let autoPaster = SpyAutoPaster(isTrusted: true)
    let registration = RegistrationSpy()
    let history = HistoryStore(capacity: 1_000_000, storageDirectory: FileManager.default.temporaryDirectory
        .appending(path: testDomainName("RunLifecycleHistory")))
    var expectedEffects = RunLifecycleModel.Effects()
    private var buffersSent = 0
    private var recordCounts = (success: 0, failed: 0)
    private var seenRecords: Set<UUID> = []

    init(model: RunLifecycleModel, hasResult: Bool) {
        self.model = model
        let settings = makeTestSettings()
        settings.hotkeyMode = model.hotkeyMode
        settings.autoPasteEnabled = model.autoPaste
        settings.streamingDeliveryEnabled = false
        settings.smartSpacingEnabled = false
        settings.matchesSentenceAtCaret = false
        settings.pinDeliveryTarget = false
        settings.transformsOnPause = false
        settings.lowerOtherAudioWhileRecording = false
        settings.playSounds = true
        let kind = WorkflowKind.translation(targetLanguage: "English", tonePreset: .neutral, customToneText: "")
        settings.workflowList = WorkflowList(workflows: [
            Workflow(id: UUID(), name: "Dictate", kind: kind, dictationLocaleID: "pt-BR", translationProvider: nil),
            Workflow(id: RunLifecycleModel.workflowID, name: "Workflow", kind: kind, dictationLocaleID: "pt-BR", translationProvider: nil)
        ])
        self.settings = settings
        if hasResult {
            history.append(successfulRecord(output: "Earlier result"))
        }
        seenRecords = Set(history.records.map(\.id))
        state = AppState.fixture(
            settings: settings,
            transcriberAssetManager: TranscriberAssetManager(prepare: { .installed($0) }),
            history: history,
            audioRecorder: recorder,
            transcriber: transcriber,
            transformer: transformer,
            pasteboard: pasteboard,
            feedback: feedback,
            metrics: metrics,
            autoPaster: autoPaster,
            errorResetSleeper: timers.sleeper(.errorReset),
            feedbackFlashSleeper: timers.sleeper(.flash),
            maximumRecordingDurationNanoseconds: 1,
            recordingDurationSleeper: timers.sleeper(.duration),
            autoPasteDelayNanoseconds: 0,
            autoPasteSleeper: timers.sleeper(.pasteDelay),
            recordingClock: clock
        )
        state.installHotkeys(registration: registration)
    }

    /// Does the action's synchronous part, exactly as the shortcut, menu, timer, or completion would.
    func perform(_ action: RunLifecycleModel.Action) {
        switch action {
        case .press(let trigger): state.triggerPressed(workflowID: id(trigger))
        case .release(let trigger): state.triggerReleased(workflowID: id(trigger))
        case .revisionPress: state.revisionTriggerPressed()
        case .revisionRelease: state.revisionTriggerReleased()
        case .revisionMenu: state.performRevisionMenuAction()
        case .escape: state.cancelRequested()
        case .pause: state.isHotkeyPaused = true
        case .resume: state.isHotkeyPaused = false
        case .copyLast(let works):
            pasteboard.failuresRemaining = works ? 0 : 1
            state.copyLastResult()
            pasteboard.failuresRemaining = 0
        case .copyResultAgain(let works):
            pasteboard.failuresRemaining = works ? 0 : 1
            state.copyPendingResult()
            pasteboard.failuresRemaining = 0
        case .holdPasses: clock.advance(by: .milliseconds(300))
        case .buffer(let quiet):
            buffersSent += 1
            recorder.yield(dBFS: quiet ? RunLifecycleModel.quietLevel : RunLifecycleModel.loudLevel)
        case .tailDeadline: clock.advance(by: .milliseconds(200))
        case .durationLimit: timers.fire(.duration)
        case .microphoneFails: recorder.fail()
        case .transcript(let result): transcriber.resolveNewest(result)
        case .transform(let result):
            if case .output(clipboardWorks: false) = result { pasteboard.failuresRemaining = 1 }
            transformer.resolveNewest(result)
        case .pasteDelayEnds: timers.fire(.pasteDelay)
        case .flashEnds: timers.fire(.flash)
        case .errorResetFires: timers.fire(.errorReset)
        case .staleTranscript: transcriber.resolveOldest(.text)
        case .staleTransform: transformer.resolveOldest(.output(clipboardWorks: true))
        case .racedTranscript(let racer):
            transcriber.resolveNewest(.text)
            race(racer)
        case .racedTransform(let racer):
            transformer.resolveNewest(.output(clipboardWorks: true))
            race(racer)
        }
    }

    private func race(_ racer: RunLifecycleModel.Racer) {
        switch racer {
        case .escape: state.cancelRequested()
        case .press: state.triggerPressed(workflowID: nil)
        }
    }

    private func id(_ trigger: RunLifecycleModel.Trigger) -> UUID? {
        trigger == .workflow ? RunLifecycleModel.workflowID : nil
    }

    func expectedObservation(of model: RunLifecycleModel.State) -> RunObservation {
        RunObservation(
            pipeline: model.pipeline,
            run: model.run.map { run in
                RunObservation.RunView(
                    isRevision: run.purpose == .revision, fromWorkflowShortcut: run.purpose == .dictation(.workflow),
                    phase: run.phase, committed: run.committed, failed: run.failed, lastBufferQuiet: run.lastBufferQuiet
                )
            },
            hasResult: model.hasResult,
            hasPendingResult: model.hasPendingResult,
            paused: model.paused,
            flash: model.flash,
            escapeEnabled: model.escapeAvailable,
            transcriptionsInFlight: (model.run?.transcriptPending == true ? 1 : 0) + model.staleTranscripts,
            transformsInFlight: (model.run?.transformPending == true ? 1 : 0) + model.staleTransforms,
            flashTimers: model.flash ? 1 : 0,
            errorResetTimers: model.errorReset ? 1 : 0,
            durationTimers: model.run?.durationTimerPending == true ? 1 : 0,
            pasteDelays: model.run?.position == .waitingForPaste ? 1 : 0,
            tailDeadlines: model.run?.phase == .releaseTail ? 1 : 0,
            bufferLevelsHandled: buffersSent,
            effects: expectedEffects
        )
    }

    func observation() -> RunObservation {
        // New records are always at the front.
        for record in history.records.prefix(while: { seenRecords.contains($0.id) == false }) {
            seenRecords.insert(record.id)
            if case .success = record.outcome { recordCounts.success += 1 } else { recordCounts.failed += 1 }
        }
        let pipeline: PipelineState = state.pipelineState.isError ? RunLifecycleModel.failure : state.pipelineState
        return RunObservation(
            pipeline: pipeline,
            run: state.activeRun.map { run in
                RunObservation.RunView(
                    isRevision: run.configuration.purpose.isRevision,
                    fromWorkflowShortcut: run.triggerWorkflowID == RunLifecycleModel.workflowID,
                    phase: run.recordingPhase, committed: run.deliveryCommitted, failed: run.failure != nil,
                    lastBufferQuiet: run.lastBufferWasQuiet
                )
            },
            hasResult: state.results.lastSuccessfulResult != nil,
            hasPendingResult: state.results.pendingClipboardResult != nil,
            paused: state.isHotkeyPaused,
            flash: state.status.isShowingSuccess,
            escapeEnabled: registration.enabled.contains(.cancelDictation),
            transcriptionsInFlight: transcriber.inFlight,
            transformsInFlight: transformer.inFlight,
            flashTimers: timers.pending(.flash),
            errorResetTimers: timers.pending(.errorReset),
            durationTimers: timers.pending(.duration),
            pasteDelays: timers.pending(.pasteDelay),
            tailDeadlines: clock.sleeping,
            bufferLevelsHandled: metrics.bufferLevelCount,
            effects: RunLifecycleModel.Effects(
                clipboardWrites: pasteboard.writes.count,
                successRecords: recordCounts.success,
                failedRecords: recordCounts.failed,
                pastes: autoPaster.pasteCount,
                errorsShown: feedback.errorMessages.count + feedback.transformationFailures.count,
                autoStopNotices: feedback.autoStoppedDurations.count,
                flashesStarted: feedback.successSoundCount
            )
        )
    }

    /// Lets the app run until it matches `expected` and stays there, or reports how it differs.
    func settle(expecting expected: RunObservation) async -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        var checks = 0
        while true {
            if observation() == expected {
                for _ in 0..<3 { await Task.yield() }
                if observation() == expected { return nil }
            }
            guard clock.now < deadline else {
                let actual = observation()
                return "Expected (model) vs actual (app):\n\(expected.differences(from: actual))"
            }
            checks += 1
            if checks.isMultiple(of: 25) {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                await Task.yield()
            }
        }
    }

    /// Ends whatever is left, so no task outlives the walk.
    func finish() async {
        state.cancelRequested()
        tearDown()
        await state.waitForPendingWork()
    }

    func tearDown() {
        transcriber.failAll()
        transformer.failAll()
        timers.cancelAll()
        clock.cancelAll()
        recorder.stop()
    }
}

// MARK: - Fakes the test drives

/// A transcriber that returns only when the test says so. It drains the audio, as a live
/// transcriber does, so the level tap never backs up. It ignores cancellation, like a recognizer
/// that is already finishing, so a cancelled run's late result reaches the app.
@MainActor
final class GatedTranscriber: Transcriber {
    private var waiting: [CheckedContinuation<String, any Error>] = []
    var inFlight: Int { waiting.count }

    nonisolated func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        Task.detached {
            do { for try await _ in audio {} } catch {}
        }
        return try await wait()
    }

    private func wait() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            waiting.append(continuation)
        }
    }

    func resolveNewest(_ result: RunLifecycleModel.Transcript) {
        guard waiting.isEmpty == false else { return }
        resume(waiting.removeLast(), with: result)
    }

    func resolveOldest(_ result: RunLifecycleModel.Transcript) {
        guard waiting.isEmpty == false else { return }
        resume(waiting.removeFirst(), with: result)
    }

    func failAll() {
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume(throwing: CancellationError()) }
    }

    private func resume(_ continuation: CheckedContinuation<String, any Error>, with result: RunLifecycleModel.Transcript) {
        switch result {
        case .text: continuation.resume(returning: "bom dia")
        case .empty: continuation.resume(returning: "   ")
        case .failure: continuation.resume(throwing: FakeFailure.transcriber)
        }
    }
}

/// A provider that returns only when the test says so, and ignores cancellation.
@MainActor
final class GatedTransformer: TextTransformer {
    private var waiting: [CheckedContinuation<String, any Error>] = []
    var inFlight: Int { waiting.count }

    nonisolated func transform(_ text: String, instruction: String) async throws -> String {
        try await wait()
    }

    private func wait() async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            waiting.append(continuation)
        }
    }

    func resolveNewest(_ result: RunLifecycleModel.Transform) {
        guard waiting.isEmpty == false else { return }
        resume(waiting.removeLast(), with: result)
    }

    func resolveOldest(_ result: RunLifecycleModel.Transform) {
        guard waiting.isEmpty == false else { return }
        resume(waiting.removeFirst(), with: result)
    }

    func failAll() {
        let all = waiting
        waiting = []
        for continuation in all { continuation.resume(throwing: CancellationError()) }
    }

    private func resume(_ continuation: CheckedContinuation<String, any Error>, with result: RunLifecycleModel.Transform) {
        switch result {
        case .output: continuation.resume(returning: "Good morning")
        case .failure: continuation.resume(throwing: FakeFailure.transformer)
        }
    }
}

/// The flash, error-reset, duration, and paste-delay sleepers. Each sleeps until the test fires it
/// and stops at once when its task is cancelled, as `Task.sleep` does.
@MainActor
final class ManualTimers {
    enum Kind: Hashable { case flash, errorReset, duration, pasteDelay }
    private var sleeping: [Kind: [UUID: CheckedContinuation<Void, any Error>]] = [:]

    func pending(_ kind: Kind) -> Int { sleeping[kind]?.count ?? 0 }

    nonisolated func sleeper(_ kind: Kind) -> @Sendable (UInt64) async throws -> Void {
        { [self] _ in try await sleep(kind) }
    }

    private func sleep(_ kind: Kind) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                register(continuation, kind: kind, id: id)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(kind, id) }
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, any Error>, kind: Kind, id: UUID) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            sleeping[kind, default: [:]][id] = continuation
        }
    }

    func fire(_ kind: Kind) {
        guard let (id, continuation) = sleeping[kind]?.first else { return }
        sleeping[kind]?[id] = nil
        continuation.resume()
    }

    func cancelAll() {
        let all = sleeping.values.flatMap(\.values)
        sleeping = [:]
        for continuation in all { continuation.resume(throwing: CancellationError()) }
    }

    private func cancel(_ kind: Kind, _ id: UUID) {
        sleeping[kind]?.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}

/// A recording clock that moves only when the test advances it.
@MainActor
final class ConformanceClock: RecordingClock {
    private let origin = ContinuousClock.now
    private var elapsed = Duration.zero
    private var sleepers: [UUID: (deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, any Error>)] = [:]
    var now: ContinuousClock.Instant { origin + elapsed }
    var sleeping: Int { sleepers.count }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                register(continuation, deadline: deadline, id: id)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func register(_ continuation: CheckedContinuation<Void, any Error>, deadline: ContinuousClock.Instant, id: UUID) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else if deadline <= now {
            continuation.resume()
        } else {
            sleepers[id] = (deadline, continuation)
        }
    }

    private func cancel(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    func advance(by duration: Duration) {
        elapsed += duration
        for (id, sleeper) in sleepers where sleeper.deadline <= now {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }

    func cancelAll() {
        let all = sleepers.values.map(\.continuation)
        sleepers = [:]
        for continuation in all { continuation.resume(throwing: CancellationError()) }
    }
}

/// A microphone that yields buffers at chosen levels and can fail on command.
@MainActor
final class ConformanceRecorder: AudioRecording {
    var onFailure: (@MainActor (any Error) -> Void)?
    private var continuation: AudioBufferSequence.Continuation?
    /// A run's microphone is open: started, and not yet stopped or finished.
    var isCapturing: Bool { continuation != nil }

    func start() async throws -> AudioBufferSequence {
        let (stream, continuation) = AudioBufferSequence.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        continuation?.finish()
        continuation = nil
    }

    func finish() async throws {
        stop()
    }

    func yield(dBFS: Double) {
        continuation?.yield(LevelRecorder.buffer(dBFS: dBFS))
    }

    func fail() {
        onFailure?(FakeFailure.recorder)
    }
}

@MainActor
final class RegistrationSpy: HotkeyRegistering {
    private(set) var enabled: Set<KeyboardShortcuts.Name> = []
    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {}
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {}
    func enable(_ name: KeyboardShortcuts.Name) { enabled.insert(name) }
    func disable(_ name: KeyboardShortcuts.Name) { enabled.remove(name) }
}
