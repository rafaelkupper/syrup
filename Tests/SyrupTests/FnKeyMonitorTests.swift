import Foundation
import KeyboardShortcuts
import Testing
@testable import Syrup

struct FnKeyGestureTests {
    private func sample(_ time: TimeInterval, fn: Bool, others: Bool = false, lastKeyAt: TimeInterval = -100) -> FnKeySample {
        FnKeySample(isFnDown: fn, hasOtherModifiers: others, secondsSinceKeyDown: time - lastKeyAt, time: time)
    }

    @Test func holdingAndReleasingFnAloneIsAGesture() {
        var gesture = FnKeyGesture()
        #expect(gesture.advance(sample(0, fn: false)) == nil)
        #expect(gesture.advance(sample(1, fn: true)) == .pressed)
        #expect(gesture.advance(sample(2, fn: true)) == nil)
        #expect(gesture.advance(sample(3, fn: false)) == .released(heldFor: 2))
    }

    @Test func anotherKeyDuringTheHoldMakesItACombination() {
        var gesture = FnKeyGesture()
        #expect(gesture.advance(sample(1, fn: true)) == .pressed)
        #expect(gesture.advance(sample(1.5, fn: true, lastKeyAt: 1.2)) == .combined)
        #expect(gesture.advance(sample(2, fn: true, lastKeyAt: 1.2)) == nil)
        #expect(gesture.advance(sample(3, fn: false, lastKeyAt: 1.2)) == nil)
    }

    @Test func aKeyPressedBeforeFnDoesNotCount() {
        var gesture = FnKeyGesture()
        #expect(gesture.advance(sample(1, fn: true, lastKeyAt: 0.9)) == .pressed)
        #expect(gesture.advance(sample(2, fn: true, lastKeyAt: 0.9)) == nil)
    }

    @Test func otherModifiersAreNotFnAlone() {
        var gesture = FnKeyGesture()
        #expect(gesture.advance(sample(1, fn: true, others: true)) == nil)
        #expect(gesture.advance(sample(2, fn: true)) == nil)
        #expect(gesture.advance(sample(3, fn: false)) == nil)
        #expect(gesture.advance(sample(4, fn: true)) == .pressed)
        #expect(gesture.advance(sample(5, fn: true, others: true)) == .combined)
    }

    /// Whether this tap completed a double-tap.
    private func tap(_ gesture: inout FnKeyGesture, at time: TimeInterval, for held: TimeInterval = 0.1) -> Bool {
        _ = gesture.advance(sample(time, fn: true))
        guard case .released(_, let completesDoubleTap)? = gesture.advance(sample(time + held, fn: false)) else {
            Issue.record("Expected a release")
            return false
        }
        return completesDoubleTap
    }

    @Test func twoQuickTapsCompleteADoubleTap() {
        var gesture = FnKeyGesture()
        #expect(tap(&gesture, at: 1) == false)
        #expect(tap(&gesture, at: 1.3))
    }

    @Test func theDoubleTapWindowIsEnforced() {
        var inside = FnKeyGesture()
        _ = tap(&inside, at: 1)
        #expect(tap(&inside, at: 1.09 + FnKeyGesture.doubleTapWindow))

        var outside = FnKeyGesture()
        _ = tap(&outside, at: 1)
        #expect(tap(&outside, at: 1.11 + FnKeyGesture.doubleTapWindow) == false)
    }

    @Test func aHoldIsNeitherHalfOfADoubleTap() {
        var longFirst = FnKeyGesture()
        _ = tap(&longFirst, at: 1, for: 0.5)
        #expect(tap(&longFirst, at: 1.6) == false)

        var longSecond = FnKeyGesture()
        _ = tap(&longSecond, at: 1)
        #expect(tap(&longSecond, at: 1.2, for: 0.5) == false)
    }

    @Test func aThirdTapStartsOver() {
        var gesture = FnKeyGesture()
        _ = tap(&gesture, at: 1)
        #expect(tap(&gesture, at: 1.2))
        #expect(tap(&gesture, at: 1.4) == false)
        #expect(tap(&gesture, at: 1.6))
    }

    @Test func aCombinationClearsTheFirstTap() {
        var gesture = FnKeyGesture()
        _ = tap(&gesture, at: 1)
        #expect(gesture.advance(sample(1.2, fn: true)) == .pressed)
        #expect(gesture.advance(sample(1.25, fn: true, lastKeyAt: 1.22)) == .combined)
        #expect(gesture.advance(sample(1.3, fn: false, lastKeyAt: 1.22)) == nil)
        #expect(tap(&gesture, at: 1.4) == false)
    }

    @Test func fnWithAModifierClearsTheFirstTap() {
        var gesture = FnKeyGesture()
        _ = tap(&gesture, at: 1)
        #expect(gesture.advance(sample(1.2, fn: true, others: true)) == nil)
        #expect(gesture.advance(sample(1.3, fn: false)) == nil)
        #expect(tap(&gesture, at: 1.4) == false)
    }
}

@MainActor
struct FnKeyHotkeyTests {
    private final class Keys {
        var current = FnKeySample(isFnDown: false, hasOtherModifiers: false, secondsSinceKeyDown: 100, time: 0)
        func set(_ time: TimeInterval, fn: Bool, lastKeyAgo: TimeInterval = 100) {
            current = FnKeySample(isFnDown: fn, hasOtherModifiers: false, secondsSinceKeyDown: lastKeyAgo, time: time)
        }
    }

    @MainActor private struct Fixture {
        let suite = testDomainName("SyrupFnKeyTests")
        let keys = Keys()
        let settings: AppSettings
        let state: AppState
        let monitor: FnKeyMonitor
        let controller: HotkeyController
        let pasteboard = SpyPasteboard()
        let metrics = SpyPipelineMetrics()

        init(
            mode: HotkeyMode = .hold,
            typing: Bool = false,
            clock: any RecordingClock = FastForwardClock(),
            transformer: FakeTextTransformer = FakeTextTransformer(.success("fixture"))
        ) {
            let settings = AppSettings(userDefaults: TestDefaults(suiteName: suite)!, defaultMicrophoneIDProvider: { "" })
            settings.hotkeyMode = mode
            let state = AppState.fixture(
                settings: settings, audioRecorder: FakeRecorder(),
                transcriber: FakeTranscriber(.success("fixture")), transformer: transformer,
                pasteboard: pasteboard, feedback: SpyFeedback(), metrics: metrics, autoPaster: SpyAutoPaster(),
                maximumRecordingDurationNanoseconds: 0, recordingClock: clock
            )
            let keys = self.keys
            let monitor = FnKeyMonitor(sample: { keys.current })
            self.settings = settings
            self.state = state
            self.monitor = monitor
            controller = HotkeyController(
                appState: state, registration: FnSilentRegistration(), fnKeyMonitor: monitor, isTypingInSyrup: { typing }
            )
            controller.setFnKeyEnabled(true)
        }

        func press(_ time: TimeInterval, fn: Bool, lastKeyAgo: TimeInterval = 100) {
            keys.set(time, fn: fn, lastKeyAgo: lastKeyAgo)
            monitor.poll()
        }

        func tap(at time: TimeInterval) {
            press(time, fn: true)
            press(time + 0.1, fn: false)
        }

        func finish() {
            controller.setFnKeyEnabled(false)
            state.cancelRequested()
            UserDefaults().removePersistentDomain(forName: suite)
        }
    }

    @Test func holdStartsOnPress() {
        let fixture = Fixture()
        defer { fixture.finish() }
        fixture.press(1, fn: true)
        #expect(fixture.state.pipelineState == .recording)
    }

    @Test func aCombinationCancelsTheRunItStarted() {
        let fixture = Fixture()
        defer { fixture.finish() }
        fixture.press(1, fn: true)
        fixture.press(1.2, fn: true, lastKeyAgo: 0.1)
        #expect(fixture.state.pipelineState == .idle)
    }

    @Test func typingInSyrupIgnoresFn() {
        let fixture = Fixture(typing: true)
        defer { fixture.finish() }
        fixture.press(1, fn: true)
        #expect(fixture.state.pipelineState == .idle)
    }

    @Test func pollingRunsOnlyWhileEnabledAndListening() {
        let fixture = Fixture()
        defer { fixture.finish() }
        #expect(fixture.monitor.isRunning)
        fixture.controller.setListening(false)
        #expect(fixture.monitor.isRunning == false)
        fixture.controller.setListening(true)
        #expect(fixture.monitor.isRunning)
        fixture.controller.setFnKeyEnabled(false)
        #expect(fixture.monitor.isRunning == false)
    }

    /// Runs the release tail out on the manual clock until the run delivers.
    private func waitForDelivery(_ fixture: Fixture, _ clock: ManualRecordingClock) async {
        for _ in 0..<400 where fixture.pasteboard.writes.isEmpty || fixture.state.pipelineState != .idle {
            clock.advance(by: .milliseconds(50))
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Lets a second pass on the manual clock, as between real taps, then checks the run is still recording.
    /// A stop enters the release tail while the state still reads `.recording`, but a stop request begins
    /// the release-to-recorder-stopped stage at once and ends it when the recorder stops, so equal counts
    /// mean no stop is pending.
    private func expectStillRecording(_ fixture: Fixture, _ clock: ManualRecordingClock, sourceLocation: SourceLocation = #_sourceLocation) async {
        clock.advance(by: .seconds(1))
        let stage = PipelineMetricStage.releaseToRecorderStopped
        #expect(fixture.state.pipelineState == .recording, sourceLocation: sourceLocation)
        #expect(fixture.metrics.begunStages.filter { $0 == stage }.count
            == fixture.metrics.endedStages.filter { $0 == stage }.count, sourceLocation: sourceLocation)
        #expect(fixture.pasteboard.writes.isEmpty, sourceLocation: sourceLocation)
    }

    @Test func holdSingleTapIsStillDiscarded() {
        let fixture = Fixture(clock: ManualRecordingClock())
        defer { fixture.finish() }
        fixture.tap(at: 1)
        #expect(fixture.state.pipelineState == .idle)
        #expect(fixture.pasteboard.writes.isEmpty)
    }

    @Test func holdDoubleTapKeepsRecordingUntilTheNextDoubleTap() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        #expect(fixture.state.pipelineState == .idle)
        fixture.tap(at: 1.3)
        await expectStillRecording(fixture, clock)

        fixture.tap(at: 6)
        await expectStillRecording(fixture, clock)
        fixture.tap(at: 6.3)
        await waitForDelivery(fixture, clock)
        #expect(fixture.pasteboard.writes == ["fixture"])
        #expect(fixture.state.pipelineState == .idle)
    }

    @Test func tapsAHoldAndCombinationsDoNotStopALatchedRun() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.3)
        clock.advance(by: .seconds(5))

        fixture.tap(at: 6)
        await expectStillRecording(fixture, clock)
        fixture.press(10, fn: true)
        fixture.press(12, fn: false)
        await expectStillRecording(fixture, clock)
        fixture.press(20, fn: true)
        fixture.press(20.1, fn: true, lastKeyAgo: 0.05)
        fixture.press(20.2, fn: false)
        await expectStillRecording(fixture, clock)
    }

    @Test func homeTellsALatchedRunHowToFinishAndForgetsWhenItEnds() {
        let fixture = Fixture(clock: ManualRecordingClock())
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.3)
        #expect(fixture.state.isFnRecordingLatched)
        let headline = HomeStatus.headline(
            phase: .recording, input: .voice, mode: .hold, hasShortcut: true,
            isFnLatched: fixture.state.isFnRecordingLatched
        )
        #expect(headline == HomeStatus.Headline(before: "Listening. Double-tap Fn to finish", showsShortcut: false))

        fixture.state.cancelRequested()
        #expect(fixture.state.isFnRecordingLatched == false)
    }

    @Test func tapThenHoldIsAnOrdinaryHold() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.press(1.3, fn: true)
        clock.advance(by: .seconds(2))
        fixture.press(3.3, fn: false)
        await waitForDelivery(fixture, clock)
        #expect(fixture.pasteboard.writes == ["fixture"])
    }

    @Test func aLatchEndsWithItsRun() {
        let fixture = Fixture(clock: ManualRecordingClock())
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.3)
        fixture.state.cancelRequested()
        #expect(fixture.state.pipelineState == .idle)
        fixture.press(5, fn: true)
        #expect(fixture.state.pipelineState == .recording)
    }

    @Test(arguments: [true, false])
    func turningFnOffCancelsALatchedRun(viaPause: Bool) {
        let fixture = Fixture(clock: ManualRecordingClock())
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.3)
        if viaPause {
            fixture.controller.setListening(false)
        } else {
            fixture.controller.setFnKeyEnabled(false)
        }
        #expect(fixture.state.pipelineState == .idle)
    }

    @Test func toggleSingleTapWhileIdleDoesNothing() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(mode: .toggle, clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        #expect(fixture.state.pipelineState == .idle)
        fixture.tap(at: 10)
        #expect(fixture.state.pipelineState == .idle)
        #expect(fixture.pasteboard.writes.isEmpty)
    }

    @Test func toggleDoubleTapStartsOnTheSecondRelease() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(mode: .toggle, clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        #expect(fixture.state.pipelineState == .idle)
        fixture.press(1.3, fn: true)
        #expect(fixture.state.pipelineState == .idle)
        fixture.press(1.4, fn: false)
        await expectStillRecording(fixture, clock)
    }

    @Test func toggleSingleTapStopsARecordingAndDelivers() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(mode: .toggle, clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.3)
        await expectStillRecording(fixture, clock)
        fixture.tap(at: 6)
        await waitForDelivery(fixture, clock)
        #expect(fixture.pasteboard.writes == ["fixture"])
        #expect(fixture.state.pipelineState == .idle)
    }

    @Test func toggleSingleTapAlsoStopsARunFromTheDictateShortcut() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(mode: .toggle, clock: clock)
        defer { fixture.finish() }
        fixture.state.triggerPressed()
        await expectStillRecording(fixture, clock)
        fixture.tap(at: 1)
        await waitForDelivery(fixture, clock)
        #expect(fixture.pasteboard.writes == ["fixture"])
    }

    @Test func toggleSlowSecondTapDoesNotStart() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(mode: .toggle, clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.11 + FnKeyGesture.doubleTapWindow)
        #expect(fixture.state.pipelineState == .idle)

        // The slow tap can still be the first of a new double-tap.
        fixture.tap(at: 1.3 + FnKeyGesture.doubleTapWindow)
        await expectStillRecording(fixture, clock)
    }

    @Test func toggleLongPressesAreNotTaps() {
        let fixture = Fixture(mode: .toggle, clock: ManualRecordingClock())
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.press(1.2, fn: true)
        fixture.press(1.6, fn: false)
        #expect(fixture.state.pipelineState == .idle)
        fixture.press(1.8, fn: true)
        fixture.press(2.2, fn: false)
        #expect(fixture.state.pipelineState == .idle)
    }

    @Test func toggleLongPressDoesNotStopARecording() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(mode: .toggle, clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.3)
        fixture.press(5, fn: true)
        fixture.press(7, fn: false)
        await expectStillRecording(fixture, clock)
    }

    @Test func toggleIgnoresCombinationsWhenIdleAndWhileRecording() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(mode: .toggle, clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.press(1.2, fn: true)
        fixture.press(1.25, fn: true, lastKeyAgo: 0.01)
        fixture.press(1.3, fn: false, lastKeyAgo: 0.01)
        #expect(fixture.state.pipelineState == .idle)

        fixture.tap(at: 3)
        fixture.tap(at: 3.3)
        fixture.press(5, fn: true)
        fixture.press(5.1, fn: true, lastKeyAgo: 0.01)
        fixture.press(5.2, fn: false, lastKeyAgo: 0.01)
        await expectStillRecording(fixture, clock)
    }

    @Test func toggleDoubleTapToStopDoesNotStartAgain() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(mode: .toggle, clock: clock)
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.3)
        await expectStillRecording(fixture, clock)

        fixture.tap(at: 6)
        await waitForDelivery(fixture, clock)
        #expect(fixture.state.pipelineState == .idle)
        // The result landed between the taps, so this second tap completes a double-tap from idle.
        fixture.tap(at: 6.3)
        #expect(fixture.state.pipelineState == .idle)
        #expect(fixture.pasteboard.writes == ["fixture"])
    }

    @Test func toggleTapsDoNotCancelAResultOnItsWay() async {
        let clock = ManualRecordingClock()
        let fixture = Fixture(mode: .toggle, clock: clock, transformer: FakeTextTransformer(.suspended))
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.3)
        await expectStillRecording(fixture, clock)
        fixture.tap(at: 6)
        for _ in 0..<400 where fixture.state.pipelineState != .translating {
            clock.advance(by: .milliseconds(50))
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(fixture.state.pipelineState == .translating)

        fixture.tap(at: 8)
        #expect(fixture.state.pipelineState == .translating)
        fixture.tap(at: 8.3)
        #expect(fixture.state.pipelineState == .translating)
    }

    @Test func toggleDoubleTapDoesNotStartWhileTypingInSyrup() {
        let fixture = Fixture(mode: .toggle, typing: true, clock: ManualRecordingClock())
        defer { fixture.finish() }
        fixture.tap(at: 1)
        fixture.tap(at: 1.3)
        #expect(fixture.state.pipelineState == .idle)
    }

    @Test func theOptionIsOffByDefaultAndPersists() {
        let suite = testDomainName("SyrupFnKeyTests")
        let defaults = TestDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        #expect(settings.dictateWithFnKey == false)
        settings.dictateWithFnKey = true
        #expect(AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" }).dictateWithFnKey)
    }
}

@MainActor
private final class FnSilentRegistration: HotkeyRegistering {
    func onKeyDown(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {}
    func onKeyUp(for name: KeyboardShortcuts.Name, action: @escaping () -> Void) {}
    func enable(_ name: KeyboardShortcuts.Name) {}
    func disable(_ name: KeyboardShortcuts.Name) {}
}
