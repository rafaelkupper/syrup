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

/// The model's findings, reproduced directly on the real controller and app.
@MainActor
struct FnShortcutFindingTests {
    @Test func turningTheFnOptionOffDuringAnFnHoldLeavesTheRecordingRunning() async {
        let harness = FnShortcutHarness(model: FnShortcutModel(hotkeyMode: .hold), fnEnabled: true)
        defer { harness.tearDown() }
        await harness.perform(.fnDown)
        await harness.perform(.tick)
        await harness.perform(.tick)
        await harness.perform(.tick)
        await eventually { harness.state.pipelineState == .recording }
        await harness.perform(.fnOptionOff)
        #expect(harness.monitor.isRunning == false)
        await harness.perform(.fnUp)
        // The release is never seen, so nothing is pending that would end the run: give the app a
        // moment, then look.
        try? await Task.sleep(for: .milliseconds(100))

        withKnownIssue("F1: Fn can no longer end the recording, so it should have been cancelled") {
            #expect(harness.state.pipelineState == .idle)
        }
        #expect(harness.state.pipelineState == .recording)
        #expect(harness.registration.enabled.contains(.cancelDictation), "Esc still ends it")
        await harness.finish()
    }
}

struct FnObservation: Equatable, CustomStringConvertible {
    var app: FnShortcutModel.App
    var gesture: FnShortcutModel.Gesture
    var tapAge: Int?
    var fnStartedRun: Bool
    var latched: Bool
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

    init(model: FnShortcutModel, fnEnabled: Bool) {
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
            recordingClock: clock
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
            fnStartedRun: model.fnStartedRun, latched: model.latched, armed: model.armed,
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
            fnStartedRun: flag("fnStartedRun"), latched: flag("isFnLatched"), armed: flag("isFnDoubleTapArmed"),
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
        let deadline = clock.now + .seconds(2)
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
