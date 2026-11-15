import Foundation
import Testing
@testable import Syrup

/// Replays `FnShortcutModel` against the real `HotkeyController`, `FnKeyMonitor`, and `AppState`:
/// walks that take every transition of the model, with Fn samples, time, and run completions under
/// the test's control. After every step the controller's flags, the gesture's phase, the latch Home
/// shows, the monitor, the Escape shortcut, and the pipeline must match the model.
@MainActor
@Suite(.serialized)
struct FnShortcutConformanceTests {
    @Test(arguments: FnShortcutModelTests.configurations)
    func theRealControllerTakesEveryTransitionAsTheModelDoes(model: FnShortcutModel) async {
        let checker = ModelChecker(model)
        let tour = ConformanceCoverage.tour(for: checker)
        let clock = ContinuousClock()
        let started = clock.now
        var steps = 0
        for (walkNumber, walk) in tour.enumerated() {
            var current = checker.states[walk.start]
            let harness = FnShortcutHarness(model: model, fnEnabled: current.fnEnabled)
            defer { harness.tearDown() }
            if let mismatch = await harness.settle(expecting: harness.expectedObservation(of: current)) {
                Issue.record("Walk \(walkNumber) starts out of step with the model:\n\(mismatch)")
                return
            }
            for (index, step) in walk.steps.enumerated() {
                let next = checker.states[step.target]
                await harness.perform(step.action)
                steps += 1
                if let mismatch = await harness.settle(expecting: harness.expectedObservation(of: next)) {
                    Issue.record(Comment(rawValue: """
                        The real controller left the model at walk \(walkNumber), step \(index) (\(model.hotkeyMode)).
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
        print("FnShortcutConformance \(model.hotkeyMode): \(steps) steps in \(tour.count) walks, \(started.duration(to: clock.now))")
    }
}

/// The model's findings F1 to F3, reproduced directly on the real controller and app, and the
/// behavior their fix keeps.
@MainActor
struct FnShortcutFixTests {
    private func harness(_ mode: HotkeyMode) -> FnShortcutHarness {
        FnShortcutHarness(model: FnShortcutModel(hotkeyMode: mode), fnEnabled: true)
    }

    private func perform(_ actions: [FnShortcutModel.Action], on harness: FnShortcutHarness) async {
        for action in actions { await harness.perform(action) }
    }

    /// F1: Fn could no longer end the recording, so it must not keep the microphone open.
    @Test(arguments: [HotkeyMode.hold, .toggle])
    func turningTheFnOptionOffCancelsARecordingFnStarted(mode: HotkeyMode) async {
        let harness = harness(mode)
        defer { harness.tearDown() }
        // Hold: a press held past the minimum hold. Toggle: a double-tap.
        await perform(mode == .hold ? [.fnDown, .tick, .tick, .tick] : [.fnDown, .fnUp, .fnDown, .fnUp], on: harness)
        #expect(harness.state.pipelineState == .recording)
        await eventually { harness.recorder.isCapturing }

        await harness.perform(.fnOptionOff)
        #expect(harness.monitor.isRunning == false)
        #expect(harness.state.pipelineState == .idle)
        #expect(harness.recorder.isCapturing == false)
        await harness.finish()
    }

    /// F2: a double-tap whose second run the shortcut already ended must not latch, or Home shows
    /// "Double-tap Fn to finish" with nothing recording.
    @Test func aDoubleTapDoesNotLatchARunThatAlreadyEnded() async {
        let harness = harness(.hold)
        defer { harness.tearDown() }
        await perform([.fnDown, .fnUp, .fnDown, .dictateRelease], on: harness)
        #expect(harness.state.pipelineState == .idle)
        await harness.perform(.fnUp)
        #expect(harness.state.isFnRecordingLatched == false)
        #expect(harness.observation().latched == false)
        await harness.finish()
    }

    /// F2: a double-tap whose second run the duration limit already stopped must not latch it while
    /// it is transcribed.
    @Test func aDoubleTapDoesNotLatchARunBeingTranscribed() async {
        let harness = harness(.hold)
        defer { harness.tearDown() }
        await perform([.fnDown, .fnUp, .fnDown], on: harness)
        await eventually { harness.recorder.isCapturing && harness.timers.pending(.duration) == 1 }
        await harness.perform(.durationLimit)
        await eventually { harness.state.pipelineState == .transcribing }

        await harness.perform(.fnUp)
        #expect(harness.observation().latched == false)
        #expect(harness.state.isFnRecordingLatched == false)
        await harness.finish()
    }

    /// F2: a latch outlived a run Esc cancelled, and turning the Fn option off then cancelled the
    /// next run, which the dictate shortcut started.
    @Test func aLatchEndsWithItsRunSoTurningFnOffSparesTheNextRun() async {
        let harness = harness(.hold)
        defer { harness.tearDown() }
        await perform([.fnDown, .fnUp, .fnDown, .fnUp], on: harness)
        #expect(harness.state.isFnRecordingLatched)
        await perform([.escape, .dictatePress], on: harness)
        #expect(harness.state.pipelineState == .recording)
        #expect(harness.observation().latched == false)

        await harness.perform(.fnOptionOff)
        #expect(harness.state.pipelineState == .recording)
        await harness.finish()
    }

    /// F2: a latch outlived a run the duration limit stopped, and turning the Fn option off then
    /// cancelled its transcription, so the dictation was lost.
    @Test func turningFnOffDoesNotCancelALatchedRunThatIsBeingTranscribed() async {
        let harness = harness(.hold)
        defer { harness.tearDown() }
        await perform([.fnDown, .fnUp, .fnDown, .fnUp], on: harness)
        await eventually { harness.recorder.isCapturing && harness.timers.pending(.duration) == 1 }
        await harness.perform(.durationLimit)
        await eventually { harness.state.pipelineState == .transcribing }
        #expect(harness.observation().latched == false)

        await harness.perform(.fnOptionOff)
        #expect(harness.state.pipelineState == .transcribing)
        await harness.finish()
    }

    /// F3: Fn's run ended and the shortcut started another while Fn was still held; releasing Fn,
    /// or pressing another key with it, ended the shortcut's run.
    @Test(arguments: [FnShortcutModel.Action.dictateRelease, .escape], [FnShortcutModel.Action.fnUp, .keyWhileFnDown])
    func fnDoesNotEndARunTheShortcutStartedAfterFnsRunEnded(fnRunEnds: FnShortcutModel.Action, fnAction: FnShortcutModel.Action) async {
        let harness = harness(.hold)
        defer { harness.tearDown() }
        await perform([.fnDown, fnRunEnds, .dictatePress], on: harness)
        #expect(harness.state.pipelineState == .recording)

        await harness.perform(fnAction)
        #expect(harness.state.pipelineState == .recording)
        await harness.finish()
    }

    /// Kept: a recording the shortcut already stopped finishes its release tail and is transcribed,
    /// even if the Fn option is turned off before the tail ends.
    @Test func turningFnOffDuringTheReleaseTailLetsTheRunFinish() async {
        let harness = harness(.hold)
        defer { harness.tearDown() }
        await perform([.fnDown, .tick, .tick, .tick], on: harness)
        await eventually { harness.recorder.isCapturing }
        // No quiet buffer has arrived, so the stop waits in the release tail.
        await harness.perform(.dictateRelease)
        #expect(harness.state.activeRun?.recordingPhase == .releaseTail)

        await harness.perform(.fnOptionOff)
        #expect(harness.state.pipelineState == .recording)
        await eventually { harness.clock.sleeping > 0 }
        harness.clock.advance(by: ReleaseTail.deadline)
        await eventually { harness.state.pipelineState == .transcribing }
        await harness.finish()
    }

    /// Kept: a selection-input run Fn started records nothing, so turning the Fn option off leaves
    /// it to finish.
    @Test func turningFnOffLeavesASelectionRunFnStartedToFinish() async {
        let harness = FnShortcutHarness(model: FnShortcutModel(hotkeyMode: .hold), fnEnabled: true,
                                        selectionReader: FakeSelectionReader(.text("Selected fixture text")))
        defer { harness.tearDown() }
        harness.settings.updateWorkflow(id: harness.settings.activeWorkflow.id) { $0.input = .selection }
        await harness.perform(.fnDown)
        #expect(harness.state.pipelineState == .translating)

        await harness.perform(.fnOptionOff)
        #expect(harness.state.pipelineState == .translating)
        await eventually { harness.transformer.inFlight == 1 }
        harness.transformer.resolveNewest(.output(clipboardWorks: true))
        await eventually { harness.state.pipelineState == .idle && harness.state.activeRun == nil }
        await harness.finish()
    }

    /// Kept: Fn with another key still cancels the run Fn's press started after the shortcut
    /// stopped it, while it is being transcribed.
    @Test func fnWithAnotherKeyStillCancelsItsOwnRunDuringTranscription() async {
        let harness = harness(.hold)
        defer { harness.tearDown() }
        await perform([.fnDown, .tick, .tick, .tick], on: harness)
        await eventually { harness.recorder.isCapturing }
        harness.recorder.yield(dBFS: RunLifecycleModel.quietLevel)
        await eventually { harness.state.activeRun?.lastBufferWasQuiet == true }
        await harness.perform(.dictateRelease)
        await eventually { harness.state.pipelineState == .transcribing }

        await harness.perform(.keyWhileFnDown)
        #expect(harness.state.pipelineState == .idle)
        await harness.finish()
    }
}

struct FnObservation: Equatable, CustomStringConvertible {
    var app: FnShortcutModel.App
    var gesture: FnShortcutModel.Gesture
    var tapAge: Int?
    var fnStartedRun: Bool
    var latched: Bool
    var fnStartedToggleRun: Bool
    var armed: Bool
    var latchedMirror: Bool
    var monitorRunning: Bool
    var escapeEnabled: Bool

    var description: String {
        Mirror(reflecting: self).children.map { "\($0.label ?? "?"): \($0.value)" }.joined(separator: ", ")
    }

    func differences(from other: FnObservation) -> String {
        let mine = Mirror(reflecting: self).children.map { ($0.label ?? "?", "\($0.value)") }
        let theirs = Mirror(reflecting: other).children.map { "\($0.value)" }
        return zip(mine, theirs).filter { $0.0.1 != $0.1 }
            .map { "    \($0.0.0): model \($0.0.1), app \($0.1)" }.joined(separator: "\n")
    }
}

@MainActor
final class FnShortcutHarness {
    let model: FnShortcutModel
    let settings: AppSettings
    let state: AppState
    let monitor: FnKeyMonitor
    let controller: HotkeyController
    let registration = RegistrationSpy()
    let recorder = ConformanceRecorder()
    let transcriber = GatedTranscriber()
    let transformer = GatedTransformer()
    let timers = ManualTimers()
    let clock = ConformanceClock()
    private var fnTime: TimeInterval = 1_000
    private var fnDown = false
    private var modifierDown = false
    private var lastKeyDown: TimeInterval = 0
    private var typing = false
    private var quietBufferSent: Set<UUID> = []

    init(model: FnShortcutModel, fnEnabled: Bool, selectionReader: any SelectionReading = FakeSelectionReader(.empty)) {
        self.model = model
        let settings = makeTestSettings()
        settings.hotkeyMode = model.hotkeyMode
        settings.dictateWithFnKey = fnEnabled
        settings.autoPasteEnabled = false
        settings.streamingDeliveryEnabled = false
        settings.transformsOnPause = false
        settings.lowerOtherAudioWhileRecording = false
        self.settings = settings
        state = AppState.fixture(
            settings: settings,
            transcriberAssetManager: TranscriberAssetManager(prepare: { .installed($0) }),
            audioRecorder: recorder,
            transcriber: transcriber,
            transformer: transformer,
            errorResetSleeper: timers.sleeper(.errorReset),
            feedbackFlashSleeper: timers.sleeper(.flash),
            maximumRecordingDurationNanoseconds: 1,
            recordingDurationSleeper: timers.sleeper(.duration),
            autoPasteSleeper: timers.sleeper(.pasteDelay),
            recordingClock: clock,
            selectionReader: selectionReader
        )
        var sampleSource: (() -> FnKeySample)?
        monitor = FnKeyMonitor(sample: { sampleSource?() ?? FnKeySample(isFnDown: false, hasOtherModifiers: false, secondsSinceKeyDown: 100, time: 0) })
        var typingSource: (() -> Bool)?
        controller = HotkeyController(appState: state, registration: registration, fnKeyMonitor: monitor,
                                      isTypingInSyrup: { typingSource?() ?? false })
        sampleSource = { [unowned self] in sample() }
        typingSource = { [unowned self] in typing }
        state.install(controller)
    }

    private func sample() -> FnKeySample {
        FnKeySample(isFnDown: fnDown, hasOtherModifiers: modifierDown, secondsSinceKeyDown: fnTime - lastKeyDown, time: fnTime)
    }

    /// The Fn monitor's timer polls every 30 ms while it runs; the test polls at once instead.
    private func pollIfRunning() {
        if monitor.isRunning { monitor.poll() }
    }

    func perform(_ action: FnShortcutModel.Action) async {
        switch action {
        case .fnDown, .fnDownWithModifier:
            fnDown = true
            modifierDown = action == .fnDownWithModifier
            pollIfRunning()
        case .fnUp:
            fnDown = false
            modifierDown = false
            pollIfRunning()
        case .keyWhileFnDown:
            // A key pressed after Fn went down. The sub-tick step is exact in binary and never
            // reaches a threshold, because the gesture ignores Fn from here until it is released.
            fnTime += 1.0 / 1024
            lastKeyDown = fnTime - 1.0 / 2048
            pollIfRunning()
        case .tick:
            fnTime += FnShortcutModel.tick
            clock.advance(by: .milliseconds(125))
        case .dictatePress: state.triggerPressed()
        case .dictateRelease: state.triggerReleased()
        case .escape: state.cancelRequested()
        case .fnOptionOn, .fnOptionOff:
            settings.dictateWithFnKey = action == .fnOptionOn
            state.refreshWorkflowHotkeys()
            pollIfRunning()
        case .pause: state.isHotkeyPaused = true
        case .resume:
            state.isHotkeyPaused = false
            pollIfRunning()
        case .focusSyrupField: typing = true
        case .leaveSyrupField: typing = false
        case .runFinishes:
            transcriber.resolveNewest(.text)
            let deadline = ContinuousClock.now + .seconds(2)
            while transformer.inFlight == 0, ContinuousClock.now < deadline { await Task.yield() }
            transformer.resolveNewest(.output(clipboardWorks: true))
        case .runFails: transcriber.resolveNewest(.failure)
        case .errorClears: timers.fire(.errorReset)
        case .durationLimit: timers.fire(.duration)
        }
    }

    func expectedObservation(of model: FnShortcutModel.State) -> FnObservation {
        FnObservation(
            app: Self.abstract(model.app), gesture: model.gesture, tapAge: model.tapAge,
            fnStartedRun: model.fnStartedRun, latched: model.latched, fnStartedToggleRun: model.fnStartedToggleRun, armed: model.armed,
            latchedMirror: model.latchedMirror, monitorRunning: model.monitorRunning, escapeEnabled: model.escapeAvailable
        )
    }

    /// Recording age and who started a run are not observable; the steps that depend on them are.
    private static func abstract(_ app: FnShortcutModel.App) -> FnShortcutModel.App {
        if case .recording = app { return .recording(age: 0, byFn: false) }
        return app
    }

    func observation() -> FnObservation {
        let app: FnShortcutModel.App = switch state.pipelineState {
        case .idle: .idle
        case .recording: .recording(age: 0, byFn: false)
        case .transcribing, .translating: .busy
        case .error: .error
        }
        let gestureMirror = Mirror(reflecting: monitor).descendant("gesture")
        let phase = gestureMirror.flatMap { Mirror(reflecting: $0).descendant("phase") }
        let gesture: FnShortcutModel.Gesture
        if let phase, String(describing: phase).hasPrefix("active"),
           let values = Mirror(reflecting: phase).children.first?.value,
           let pressedAt = Mirror(reflecting: values).descendant("pressedAt") as? Double,
           let followsTap = Mirror(reflecting: values).descendant("followsTap") as? Bool {
            gesture = .active(age: age(since: pressedAt), followsTap: followsTap)
        } else if let phase, String(describing: phase) == "ignoring" {
            gesture = .ignoring
        } else {
            gesture = .up
        }
        let lastTap = gestureMirror.flatMap { Mirror(reflecting: $0).descendant("lastTapEndedAt") }
            .flatMap { Mirror(reflecting: $0).children.first?.value as? Double }
        return FnObservation(
            app: app, gesture: gesture, tapAge: lastTap.map(age(since:)),
            fnStartedRun: flag("fnStartedRun"), latched: flag("isFnLatched"),
            fnStartedToggleRun: flag("fnStartedToggleRun"), armed: flag("isFnDoubleTapArmed"),
            latchedMirror: state.isFnRecordingLatched, monitorRunning: monitor.isRunning,
            escapeEnabled: registration.enabled.contains(.cancelDictation)
        )
    }

    private func flag(_ name: String) -> Bool {
        Mirror(reflecting: controller).descendant(name) as? Bool ?? false
    }

    private func age(since time: TimeInterval) -> Int {
        min(Int(((fnTime - time) / FnShortcutModel.tick).rounded()), FnShortcutModel.ageCap)
    }

    /// Feeds each new run one quiet buffer, so its stops are immediate, as the model assumes.
    private func quietenRecordingRun() {
        guard state.pipelineState == .recording, let run = state.activeRun,
              recorder.isCapturing, quietBufferSent.insert(run.id).inserted else { return }
        recorder.yield(dBFS: RunLifecycleModel.quietLevel)
    }

    func settle(expecting expected: FnObservation) async -> String? {
        let clock = ContinuousClock()
        // Generous, because other suites share the main actor; a real mismatch never matches.
        let deadline = clock.now + .seconds(10)
        var checks = 0
        while true {
            quietenRecordingRun()
            let quiet = state.activeRun.map { $0.lastBufferWasQuiet || state.pipelineState != .recording } ?? true
            if quiet, observation() == expected {
                for _ in 0..<3 { await Task.yield() }
                if observation() == expected { return nil }
            }
            guard clock.now < deadline else {
                return "Expected (model) vs actual (app):\n\(expected.differences(from: observation()))"
            }
            checks += 1
            if checks.isMultiple(of: 25) {
                try? await Task.sleep(for: .microseconds(200))
            } else {
                await Task.yield()
            }
        }
    }

    func finish() async {
        state.cancelRequested()
        tearDown()
        await state.waitForPendingWork()
    }

    func tearDown() {
        monitor.stop()
        transcriber.failAll()
        transformer.failAll()
        timers.cancelAll()
        clock.cancelAll()
        recorder.stop()
    }
}
