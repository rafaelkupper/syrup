import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import Syrup

struct ReleaseTailDecisionTests {
    @Test(arguments: zip(
        [
            ReleaseTail.Event.bufferLevel(dBFS: -.infinity),
            .bufferLevel(dBFS: -60),
            .bufferLevel(dBFS: -45.01),
            .bufferLevel(dBFS: -45),
            .bufferLevel(dBFS: -20),
            .deadlineReached,
        ],
        [ReleaseTail.Decision.finish, .finish, .finish, .continue, .continue, .finish]
    ))
    func quietBuffersAndTheDeadlineFinishTheTail(event: ReleaseTail.Event, expected: ReleaseTail.Decision) {
        #expect(ReleaseTail.decision(after: event) == expected)
    }
}

@MainActor
struct ReleaseTailPipelineTests {
    private static let bufferInterval = Duration.seconds(4096.0 / 48_000)

    @Test
    func quietBufferAfterReleaseFinishesRecordingOnThatBuffer() async {
        let fixture = RecordingFixture()
        await fixture.startSpeaking()

        fixture.release()
        await settle()
        #expect(fixture.state.pipelineState == .recording)
        #expect(fixture.recorder.finishCount == 0)

        fixture.clock.advance(by: Self.bufferInterval)
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.recorder.finishCount == 1 }
        await waitUntil { await fixture.transformer.callCount == 1 }
        #expect(fixture.sinceRelease == Self.bufferInterval)
        #expect(await fixture.transcriber.bufferCount == 2)
        await waitUntil { fixture.pasteboard.writes == ["Good morning"] }
    }

    @Test
    func theResultRecordsTheTimeFromReleaseToClipboard() async throws {
        let fixture = RecordingFixture()
        await fixture.startSpeaking()

        fixture.release()
        await settle()
        fixture.clock.advance(by: .seconds(1.5))
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.history.records.isEmpty == false }
        #expect(try #require(fixture.history.records.first).duration == 1.5)
    }

    @Test
    func releaseAfterAQuietBufferStopsWithoutWaiting() async {
        let fixture = RecordingFixture()
        await fixture.startSpeaking()
        fixture.recorder.yield(dBFS: silence)
        await waitUntil { await fixture.transcriber.bufferCount == 2 }
        await settle()

        fixture.release()

        await waitUntil { fixture.recorder.finishCount == 1 }
        #expect(fixture.sinceRelease == .zero)
        await waitUntil { fixture.pasteboard.writes == ["Good morning"] }
    }

    @Test
    func speechAfterAQuietBufferStillTakesTheTail() async {
        let fixture = RecordingFixture()
        await fixture.startSpeaking()
        fixture.recorder.yield(dBFS: silence)
        fixture.recorder.yield(dBFS: speech)
        await waitUntil { await fixture.transcriber.bufferCount == 3 }
        await settle()

        fixture.release()
        await settle()

        #expect(fixture.recorder.finishCount == 0)
        fixture.clock.advance(by: Self.bufferInterval)
        fixture.recorder.yield(dBFS: silence)
        await waitUntil { fixture.recorder.finishCount == 1 }
        #expect(fixture.sinceRelease == Self.bufferInterval)
    }

    @Test
    func continuousSpeechAfterReleaseFinishesAtTheDeadline() async {
        let fixture = RecordingFixture()
        await fixture.startSpeaking()

        fixture.release()
        for _ in 0..<2 {
            fixture.clock.advance(by: Self.bufferInterval)
            fixture.recorder.yield(dBFS: speech)
        }
        await waitUntil { await fixture.transcriber.bufferCount == 3 }
        fixture.clock.advance(by: ReleaseTail.deadline - fixture.sinceRelease - .nanoseconds(1))
        await settle()
        #expect(fixture.recorder.finishCount == 0)
        #expect(fixture.state.pipelineState == .recording)

        fixture.clock.advance(by: .nanoseconds(1))

        await waitUntil { fixture.recorder.finishCount == 1 }
        #expect(fixture.sinceRelease == ReleaseTail.deadline)
        await waitUntil { fixture.pasteboard.writes == ["Good morning"] }
        #expect(await fixture.transcriber.bufferCount == 3)
    }

    @Test
    func releaseToRecorderStoppedSpansTheTail() async {
        let fixture = RecordingFixture()
        await fixture.startSpeaking()

        fixture.release()
        await settle()
        #expect(fixture.metrics.begunStages.contains(.releaseToRecorderStopped))
        #expect(fixture.metrics.endedStages.contains(.releaseToRecorderStopped) == false)

        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.metrics.endedStages.contains(.releaseToRecorderStopped) }
        #expect(fixture.recorder.finishCount == 1)
    }

    @Test
    func durationLimitStopsWithoutATail() async {
        let durationSleeper = ManualResetSleeper()
        let fixture = RecordingFixture(maximumRecordingDurationNanoseconds: 1_000_000_000, recordingDurationSleeper: { nanoseconds in
            try await durationSleeper.sleep(nanoseconds: nanoseconds)
        })
        await fixture.startSpeaking()
        await durationSleeper.waitForCallCount(1)
        let stoppedAt = fixture.clock.elapsed

        await durationSleeper.resumeCall(0)

        await waitUntil { fixture.recorder.finishCount == 1 }
        #expect(fixture.clock.elapsed == stoppedAt)
        #expect(await fixture.transcriber.bufferCount == 1)
        #expect(fixture.feedback.autoStoppedDurations == [1])
        await waitUntil { fixture.pasteboard.writes == ["Good morning"] }
    }

    @Test
    func finishingARevisionFromTheMenuStopsWithoutATail() async {
        let fixture = RecordingFixture(history: historyWithResult())
        fixture.state.startRevision()
        await waitUntil { fixture.recorder.startCount == 1 }
        fixture.recorder.yield(dBFS: speech)
        await waitUntil { await fixture.transcriber.bufferCount == 1 }

        fixture.state.performRevisionMenuAction()

        await waitUntil { fixture.recorder.finishCount == 1 }
        #expect(fixture.clock.elapsed == .zero)
        await waitUntil { await fixture.transformer.callCount == 1 }
    }

    @Test
    func failureDuringTheTailEndsItAtOnce() async {
        let fixture = RecordingFixture(transcriber: CountingTranscriber(failsOnFullScaleBuffer: true))
        await fixture.startSpeaking()
        fixture.release()

        fixture.recorder.yield(dBFS: 0)

        await waitUntil { fixture.state.pipelineState.isError }
        #expect(fixture.sinceRelease == .zero)
        #expect(fixture.pasteboard.writes.isEmpty)
        #expect(await fixture.transformer.callCount == 0)
    }

    @Test
    func escapeDuringTheTailDiscardsTheRun() async {
        let fixture = RecordingFixture()
        await fixture.startSpeaking()
        fixture.release()
        fixture.recorder.yield(dBFS: speech)
        await waitUntil { await fixture.transcriber.bufferCount == 2 }

        fixture.state.cancelRequested()

        #expect(fixture.state.pipelineState == .idle)
        fixture.clock.advance(by: .seconds(1))
        await settle()
        #expect(fixture.recorder.finishCount == 0)
        #expect(fixture.pasteboard.writes.isEmpty)
        #expect(fixture.history.records.isEmpty)
        #expect(await fixture.transformer.callCount == 0)
        #expect(fixture.state.pipelineState == .idle)
    }

    @Test(arguments: [HotkeyMode.hold, .toggle])
    func secondHotkeyPressDuringTheTailChangesNothing(mode: HotkeyMode) async {
        let settings = makeRecordingSettings()
        settings.hotkeyMode = mode
        let fixture = RecordingFixture(settings: settings)
        await fixture.startSpeaking()
        if mode == .hold {
            fixture.release()
        } else {
            fixture.state.triggerPressed()
        }

        fixture.state.triggerPressed()
        fixture.state.triggerReleased()
        fixture.state.triggerPressed()
        await settle()
        #expect(fixture.state.pipelineState == .recording)
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.pasteboard.writes == ["Good morning"] }
        await settle()
        #expect(fixture.recorder.startCount == 1)
        #expect(fixture.recorder.finishCount == 1)
        #expect(await fixture.transformer.callCount == 1)
        #expect(fixture.history.records.count == 1)
    }
}

@MainActor
struct ShortTapTests {
    @Test
    func holdReleasedBefore300MillisecondsIsDiscardedSilently() async {
        let settings = makeRecordingSettings()
        settings.playSounds = true
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let cue = CueStateSpy()
        let fixture = RecordingFixture(settings: settings, recordingArchive: archive, recordingCue: cue)
        fixture.state.triggerPressed()
        await waitUntil { await archive.snapshot().begunEntryIDs.count == 1 }
        fixture.clock.advance(by: .milliseconds(299))

        fixture.state.triggerReleased()

        #expect(fixture.state.pipelineState == .idle)
        #expect(fixture.state.menuBarSymbol == "waveform")
        #expect(cue.states.last == .hidden)
        await waitUntil { await archive.snapshot().discardedEntryIDs.count == 1 }
        await settle()
        #expect(fixture.recorder.finishCount == 0)
        #expect(await archive.snapshot().commits.isEmpty)
        #expect(fixture.feedback.successSoundCount == 0)
        #expect(fixture.feedback.errorMessages.isEmpty)
        #expect(fixture.feedback.transformationFailures.isEmpty)
        #expect(fixture.history.records.isEmpty)
        #expect(fixture.pasteboard.writes.isEmpty)
        #expect(await fixture.transformer.callCount == 0)
        #expect(fixture.state.pipelineState == .idle)
    }

    @Test
    func holdReleasedAt300MillisecondsProceeds() async {
        let settings = makeRecordingSettings()
        settings.playSounds = true
        let fixture = RecordingFixture(settings: settings)
        fixture.state.triggerPressed()
        await waitUntil { fixture.recorder.startCount == 1 }
        fixture.clock.advance(by: .milliseconds(300))

        fixture.state.triggerReleased()
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.pasteboard.writes == ["Good morning"] }
        #expect(fixture.feedback.successSoundCount == 1)
        #expect(fixture.history.records.count == 1)
    }

    @Test
    func toggleModeNeverDiscards() async {
        let settings = makeRecordingSettings()
        settings.hotkeyMode = .toggle
        let fixture = RecordingFixture(settings: settings)
        fixture.state.triggerPressed()
        await waitUntil { fixture.recorder.startCount == 1 }

        fixture.state.triggerPressed()
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.pasteboard.writes == ["Good morning"] }
        #expect(fixture.clock.elapsed == .zero)
    }

    @Test
    func revisionHoldReleasedEarlyIsDiscarded() async {
        let fixture = RecordingFixture(history: historyWithResult())
        fixture.state.revisionTriggerPressed()
        await waitUntil { fixture.recorder.startCount == 1 }
        fixture.clock.advance(by: .milliseconds(100))

        fixture.state.revisionTriggerReleased()

        #expect(fixture.state.pipelineState == .idle)
        await settle()
        #expect(fixture.recorder.finishCount == 0)
        #expect(fixture.history.records.count == 1)
        #expect(fixture.pasteboard.writes.isEmpty)
        #expect(fixture.feedback.errorMessages.isEmpty)
        #expect(await fixture.transformer.callCount == 0)
    }
}

@MainActor
struct RunActivityTests {
    @Test
    func successfulRunHoldsOneUserInitiatedActivityUntilItFinishes() async {
        let activities = SpyProcessActivity()
        let fixture = RecordingFixture(processActivity: activities)
        await fixture.startSpeaking()
        #expect(activities.begun.count == 1)
        #expect(activities.ended.isEmpty)

        fixture.release()
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.state.pipelineState == .idle && fixture.pasteboard.writes.count == 1 }
        #expect(activities.options == [.userInitiated])
        #expect(activities.ended == activities.begun)
    }

    @Test
    func cancelledRunEndsItsActivity() async {
        let activities = SpyProcessActivity()
        let fixture = RecordingFixture(processActivity: activities)
        await fixture.startSpeaking()

        fixture.state.cancelRequested()

        #expect(activities.begun.count == 1)
        #expect(activities.ended == activities.begun)
    }

    @Test
    func failedRunEndsItsActivity() async {
        let activities = SpyProcessActivity()
        let fixture = RecordingFixture(transformer: FakeTextTransformer(.failure(.transformer)), processActivity: activities)
        await fixture.startSpeaking()

        fixture.release()
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.state.pipelineState.isError }
        #expect(activities.begun.count == 1)
        #expect(activities.ended == activities.begun)
    }

    @Test
    func supersededRunEndsOnlyItsOwnActivity() async {
        let activities = SpyProcessActivity()
        let transformer = FakeTextTransformer(.suspended)
        let fixture = RecordingFixture(transformer: transformer, processActivity: activities)
        await fixture.startSpeaking()
        fixture.release()
        fixture.recorder.yield(dBFS: silence)
        await waitUntil { await transformer.callCount == 1 }

        fixture.state.cancelRequested()
        fixture.state.triggerPressed()

        await waitUntil { await transformer.cancellationCount == 1 }
        await waitUntil { fixture.recorder.startCount == 2 }
        await settle()
        #expect(activities.begun.count == 2)
        #expect(activities.ended == [activities.begun[0]])
        #expect(activities.reasons.count == 2 && Set(activities.reasons).count == 1)

        fixture.clock.advance(by: .seconds(1))
        fixture.release()
        fixture.recorder.yield(dBFS: silence)
        await waitUntil { await transformer.callCount == 2 }
        await transformer.succeed("Good morning")

        await waitUntil { fixture.state.pipelineState == .idle && fixture.pasteboard.writes == ["Good morning"] }
        #expect(activities.ended == activities.begun)
    }
}

@MainActor
struct OutputDuckingTests {
    private static let original: [UInt32: Float32] = [1: 0.8]
    private static let lowered: [UInt32: Float32] = [1: 0.8 * 0.3]

    @Test
    func lowersAfterRecordingStartsAndRestoresOnceAfterTheTail() async {
        let volume = VolumeControllerFake(channels: Self.original)
        let fixture = RecordingFixture(settings: Self.loweringSettings(), outputDucker: volume.makeDucker())
        await fixture.startSpeaking()
        await waitUntil { volume.writes == [Self.lowered] }

        fixture.release()
        fixture.recorder.yield(dBFS: speech)
        await waitUntil { await fixture.transcriber.bufferCount == 2 }
        await settle()
        #expect(volume.writes == [Self.lowered])
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.state.pipelineState == .idle && fixture.pasteboard.writes == ["Good morning"] }
        await settle()
        #expect(volume.writes == [Self.lowered, Self.original])
        volume.cleanUp()
    }

    @Test
    func cancelDuringTheTailRestoresOnce() async {
        let volume = VolumeControllerFake(channels: Self.original)
        let fixture = RecordingFixture(settings: Self.loweringSettings(), outputDucker: volume.makeDucker())
        await fixture.startSpeaking()
        fixture.release()
        fixture.recorder.yield(dBFS: speech)
        await waitUntil { await fixture.transcriber.bufferCount == 2 }

        fixture.state.cancelRequested()

        await waitUntil { volume.writes == [Self.lowered, Self.original] }
        await settle()
        #expect(volume.writes == [Self.lowered, Self.original])
        #expect(fixture.pasteboard.writes.isEmpty)
        volume.cleanUp()
    }

    @Test
    func failureWhileRecordingRestoresOnce() async {
        let volume = VolumeControllerFake(channels: Self.original)
        let fixture = RecordingFixture(
            settings: Self.loweringSettings(),
            transcriber: CountingTranscriber(failsOnFullScaleBuffer: true),
            outputDucker: volume.makeDucker()
        )
        await fixture.startSpeaking()
        await waitUntil { volume.writes == [Self.lowered] }

        fixture.recorder.yield(dBFS: 0)

        await waitUntil { fixture.state.pipelineState.isError }
        await waitUntil { volume.writes == [Self.lowered, Self.original] }
        volume.cleanUp()
    }

    @Test
    func disabledSettingNeverTouchesTheController() async {
        let volume = VolumeControllerFake(channels: Self.original)
        let fixture = RecordingFixture(outputDucker: volume.makeDucker())
        await fixture.startSpeaking()
        fixture.release()
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.state.pipelineState == .idle && fixture.pasteboard.writes == ["Good morning"] }
        await settle()
        #expect(volume.accessCount == 0)
        volume.cleanUp()
    }

    @Test
    func failingVolumeControlNeverFailsTheRun() async {
        let settings = Self.loweringSettings()
        settings.playSounds = true
        let volume = VolumeControllerFake(channels: Self.original, failsReads: true)
        let fixture = RecordingFixture(settings: settings, outputDucker: volume.makeDucker())
        await fixture.startSpeaking()
        fixture.release()
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.feedback.successSoundCount == 1 }
        #expect(fixture.pasteboard.writes == ["Good morning"])
        #expect(fixture.feedback.errorMessages.isEmpty)
        #expect(volume.writes.isEmpty)
        volume.cleanUp()
    }

    @Test
    func turningTheSettingOffMidRunStillRestores() async {
        let settings = Self.loweringSettings()
        let volume = VolumeControllerFake(channels: Self.original)
        let fixture = RecordingFixture(settings: settings, outputDucker: volume.makeDucker())
        await fixture.startSpeaking()
        await waitUntil { volume.writes == [Self.lowered] }

        settings.lowerOtherAudioWhileRecording = false
        fixture.release()
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.state.pipelineState == .idle }
        await waitUntil { volume.writes == [Self.lowered, Self.original] }
        volume.cleanUp()
    }

    @Test
    func slowVolumeChangesNeverDelayDeliveryButPrecedeTheSuccessSound() async {
        let settings = Self.loweringSettings()
        settings.playSounds = true
        let volume = VolumeControllerFake(channels: Self.original, holdsFirstWrite: true)
        let fixture = RecordingFixture(settings: settings, outputDucker: volume.makeDucker())
        await fixture.startSpeaking()
        fixture.release()
        fixture.recorder.yield(dBFS: silence)

        await waitUntil { fixture.pasteboard.writes == ["Good morning"] }
        #expect(fixture.feedback.successSoundCount == 0)
        #expect(volume.writes.isEmpty)

        volume.releaseFirstWrite()

        await waitUntil { fixture.feedback.successSoundCount == 1 }
        #expect(volume.writes == [Self.lowered, Self.original])
        volume.cleanUp()
    }

    @Test
    func stuckVolumeChangeStillFinishesTheRun() async {
        let settings = Self.loweringSettings()
        settings.playSounds = true
        let volume = VolumeControllerFake(channels: Self.original, holdsFirstWrite: true)
        let fixture = RecordingFixture(settings: settings, outputDucker: volume.makeDucker())
        await fixture.startSpeaking()
        fixture.release()
        fixture.recorder.yield(dBFS: silence)

        await waitUntil(timeout: .seconds(5)) { fixture.feedback.successSoundCount == 1 }
        #expect(fixture.state.pipelineState == .idle)
        #expect(volume.writes.isEmpty)
        volume.releaseFirstWrite()
        await waitUntil { volume.writes == [Self.lowered, Self.original] }
        volume.cleanUp()
    }

    private static func loweringSettings() -> AppSettings {
        let settings = makeRecordingSettings()
        settings.lowerOtherAudioWhileRecording = true
        return settings
    }
}

final class VolumeControllerFake: OutputVolumeControlling {
    private struct State {
        var channels: [UInt32: Float32]
        var writes: [[UInt32: Float32]] = []
        var accessCount = 0
    }

    private let state: Mutex<State>
    private let firstWriteGate: DispatchSemaphore?
    private let failsReads: Bool
    private let suiteName = "SyrupOutputDuckingTests.\(UUID().uuidString)"
    var writes: [[UInt32: Float32]] { state.withLock { $0.writes } }
    var accessCount: Int { state.withLock { $0.accessCount } }

    init(channels: [UInt32: Float32], holdsFirstWrite: Bool = false, failsReads: Bool = false) {
        state = Mutex(State(channels: channels))
        firstWriteGate = holdsFirstWrite ? DispatchSemaphore(value: 0) : nil
        self.failsReads = failsReads
    }

    func defaultOutputVolume() throws -> OutputVolume? {
        try current()
    }

    func volume(for deviceUID: String) throws -> OutputVolume? {
        try current()
    }

    func setVolume(_ volume: OutputVolume) {
        if state.withLock({ $0.writes.isEmpty }) {
            firstWriteGate?.wait()
        }
        state.withLock { state in
            state.accessCount += 1
            state.writes.append(volume.channels)
            state.channels.merge(volume.channels) { _, new in new }
        }
    }

    func makeDucker() -> OutputDucker {
        OutputDucker(controller: self, defaultsSuiteName: suiteName)
    }

    func releaseFirstWrite() {
        firstWriteGate?.signal()
    }

    func cleanUp() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    private func current() throws -> OutputVolume? {
        state.withLock { $0.accessCount += 1 }
        if failsReads {
            throw OutputVolumeError.readFailed(-1)
        }
        return state.withLock { OutputVolume(deviceUID: "speakers", channels: $0.channels) }
    }
}

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SYRUP_RELEASE_TIMING"] == "1"))
struct ReleasePathTimingTests {
    private static let pairs = 200

    @Test
    func quietReleaseCostAgainstAMenuStop() async throws {
        let metrics = StopTimingMetrics()
        let recorder = LevelRecorder()
        let clock = ManualRecordingClock()
        let transcriber = CountingTranscriber()
        let pasteboard = SpyPasteboard()
        let state = AppState.fixture(
            settings: makeRecordingSettings(),
            history: historyWithResult(),
            audioRecorder: recorder,
            transcriber: transcriber,
            transformer: FakeTextTransformer(.success("Good morning")),
            pasteboard: pasteboard,
            feedback: SpyFeedback(),
            metrics: metrics,
            autoPaster: SpyAutoPaster(),
            maximumRecordingDurationNanoseconds: 0,
            recordingClock: clock,
            selectionReader: FakeSelectionReader(.empty),
            captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) }
        )
        let quietBuffer = LevelRecorder.buffer(dBFS: silence)
        var tail: [Duration] = []
        var menu: [Duration] = []

        for index in 0..<(Self.pairs * 2) {
            let started = recorder.startCount
            state.revisionTriggerPressed()
            await waitUntil { recorder.startCount == started + 1 }
            let received = await transcriber.bufferCount
            recorder.yield(dBFS: speech)
            await waitUntil { await transcriber.bufferCount == received + 1 }
            clock.advance(by: .seconds(1))
            try await Task.sleep(for: .milliseconds(10))

            if index.isMultiple(of: 2) {
                state.revisionTriggerReleased()
                recorder.yield(quietBuffer)
            } else {
                state.performRevisionMenuAction()
            }
            await waitUntil { state.pipelineState == .idle && pasteboard.writes.count == index + 1 }
            if let duration = metrics.durations.last, metrics.durations.count == index + 1 {
                if index.isMultiple(of: 2) { tail.append(duration) } else { menu.append(duration) }
            }
        }

        #expect(tail.count == Self.pairs && menu.count == Self.pairs)
        #expect(clock.elapsed == .seconds(Self.pairs * 2))
        report("hotkey_quiet_tail", tail)
        report("menu_no_tail", menu)
        report("paired_difference", zip(tail, menu).map { $0 - $1 })
    }

    @Test
    func levelTapAndMainActorHops() async throws {
        let (source, continuation) = AudioBufferSequence.makeStream()
        let reported = Mutex<[ContinuousClock.Instant]>([])
        let tapped = AudioLevelTap.attach(to: source) { _ in
            reported.withLock { $0.append(.now) }
        }
        let drain = Task { for try await _ in tapped {} }
        let buffer = LevelRecorder.buffer(dBFS: silence)
        var tapLatency: [Duration] = []
        for index in 0..<1000 {
            let yieldedAt = ContinuousClock.now
            continuation.yield(buffer)
            await waitUntil { reported.withLock { $0.count } == index + 1 }
            tapLatency.append(yieldedAt.duration(to: reported.withLock { $0[index] }))
        }
        continuation.finish()
        try await drain.value

        var hopLatency: [Duration] = []
        for _ in 0..<1000 {
            let hop = await Task.detached {
                let sentAt = ContinuousClock.now
                let arrivedAt = await Task { @MainActor in ContinuousClock.now }.value
                return sentAt.duration(to: arrivedAt)
            }.value
            hopLatency.append(hop)
        }

        let clock = ContinuousClock()
        var rmsCost: [Duration] = []
        for _ in 0..<1000 {
            rmsCost.append(clock.measure { _ = buffer.rmsLevel })
        }

        report("level_tap_yield_to_callback", tapLatency)
        report("detached_to_main_actor_hop", hopLatency)
        report("rms_4096_frames", rmsCost)
    }

    private func report(_ name: String, _ samples: [Duration]) {
        let sorted = samples.map { Double($0.components.attoseconds) / 1e15 + Double($0.components.seconds) * 1e3 }.sorted()
        guard sorted.isEmpty == false else { return }
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
        print(String(
            format: "release_timing\t%@\tn=%d\tmin_ms=%.4f\tp05_ms=%.4f\tmedian_ms=%.4f\tp95_ms=%.4f\tmax_ms=%.4f",
            name, sorted.count, sorted[0], percentile(0.05), percentile(0.5), percentile(0.95), sorted[sorted.count - 1]
        ))
    }
}

@MainActor
private final class StopTimingMetrics: PipelineMetricsRecording {
    private var startedAt: [UUID: ContinuousClock.Instant] = [:]
    private(set) var durations: [Duration] = []

    func begin(_ stage: PipelineMetricStage, runID: UUID) {
        if stage == .releaseToRecorderStopped { startedAt[runID] = .now }
    }

    func end(_ stage: PipelineMetricStage, runID: UUID) {
        if stage == .releaseToRecorderStopped, let start = startedAt.removeValue(forKey: runID) {
            durations.append(start.duration(to: .now))
        }
    }

    func recordDuration(_ stage: PipelineMetricStage, duration: Duration, runID: UUID) {}
    func recordQuietBeforeRelease(_ duration: Duration, runID: UUID) {}
    func recordPauseTransformation(_ outcome: PauseTransformationOutcome, attemptCount: Int, runID: UUID) {}
    func recordDeliveryMode(_ mode: PipelineDeliveryMode, runID: UUID) {}

    func discard(runID: UUID) {}
}

@MainActor
final class SpyProcessActivity: ProcessActivityControlling {
    private(set) var begun: [NSObject] = []
    private(set) var ended: [NSObject] = []
    private(set) var options: [ProcessInfo.ActivityOptions] = []
    private(set) var reasons: [String] = []

    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol {
        let activity = NSObject()
        begun.append(activity)
        self.options.append(options)
        reasons.append(reason)
        return activity
    }

    func endActivity(_ activity: any NSObjectProtocol) {
        ended.append(activity as! NSObject)
    }
}

@MainActor
final class ManualRecordingClock: RecordingClock {
    private struct Sleeper {
        let deadline: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let origin = ContinuousClock.now
    private(set) var elapsed = Duration.zero
    private var sleepers: [UUID: Sleeper] = [:]
    var now: ContinuousClock.Instant { origin + elapsed }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                resumeDueSleepers()
            }
        } onCancel: {
            Task { @MainActor in self.cancelSleeper(id) }
        }
    }

    func advance(by duration: Duration) {
        elapsed += duration
        resumeDueSleepers()
    }

    private func resumeDueSleepers() {
        for (id, sleeper) in sleepers where sleeper.deadline <= now {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(_ id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }
}

@MainActor
final class LevelRecorder: AudioRecording {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var finishCount = 0
    private var continuation: AudioBufferSequence.Continuation?

    func start() async throws -> AudioBufferSequence {
        startCount += 1
        let (stream, continuation) = AudioBufferSequence.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func finish() async throws {
        finishCount += 1
        continuation?.finish()
        continuation = nil
    }

    func yield(dBFS: Double) {
        yield(Self.buffer(dBFS: dBFS))
    }

    func yield(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }

    nonisolated static func buffer(dBFS: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        let amplitude = Float(pow(10, dBFS / 20))
        for frame in 0..<4096 {
            buffer.floatChannelData![0][frame] = amplitude
        }
        return buffer
    }
}

actor CountingTranscriber: Transcriber {
    private let failsOnFullScaleBuffer: Bool
    private(set) var bufferCount = 0

    init(failsOnFullScaleBuffer: Bool = false) {
        self.failsOnFullScaleBuffer = failsOnFullScaleBuffer
    }

    func transcribe(_ audio: AudioBufferSequence, request: TranscriptionRequest) async throws -> String {
        for try await buffer in audio {
            bufferCount += 1
            if failsOnFullScaleBuffer, buffer.rmsLevel == 1 {
                throw TranscriptionError.audioConversionFailed
            }
        }
        return "bom dia"
    }
}

@MainActor
private final class RecordingFixture {
    let recorder = LevelRecorder()
    let clock = ManualRecordingClock()
    let transcriber: CountingTranscriber
    let transformer: FakeTextTransformer
    let pasteboard = SpyPasteboard()
    let feedback = SpyFeedback()
    let metrics = SpyPipelineMetrics()
    let history: HistoryStore
    private(set) var state: AppState!
    private var releasedAt = Duration.zero
    var sinceRelease: Duration { clock.elapsed - releasedAt }

    init(
        settings: AppSettings = makeRecordingSettings(),
        history: HistoryStore = HistoryStore(),
        transcriber: CountingTranscriber = CountingTranscriber(),
        transformer: FakeTextTransformer = FakeTextTransformer(.success("Good morning")),
        maximumRecordingDurationNanoseconds: UInt64 = 0,
        recordingDurationSleeper: @escaping RecordingDurationSleeper = { _ in },
        processActivity: any ProcessActivityControlling = ProcessInfo.processInfo,
        recordingArchive: (any RecordingArchiving)? = nil,
        recordingCue: (any RecordingCuePresenting)? = nil,
        outputDucker: OutputDucker? = nil
    ) {
        self.history = history
        self.transcriber = transcriber
        self.transformer = transformer
        state = AppState.fixture(
            settings: settings,
            history: history,
            audioRecorder: recorder,
            transcriber: transcriber,
            transformer: transformer,
            pasteboard: pasteboard,
            feedback: feedback,
            metrics: metrics,
            autoPaster: SpyAutoPaster(),
            maximumRecordingDurationNanoseconds: maximumRecordingDurationNanoseconds,
            recordingDurationSleeper: recordingDurationSleeper,
            recordingClock: clock,
            processActivity: processActivity,
            selectionReader: FakeSelectionReader(.empty),
            recordingCue: recordingCue,
            recordingArchive: recordingArchive,
            outputDucker: outputDucker,
            captureDeliveryTarget: { _ in DeliveryTarget(checkCurrent: { true }) }
        )
    }

    func startSpeaking() async {
        state.triggerPressed()
        await waitUntil { self.recorder.startCount == 1 }
        recorder.yield(dBFS: speech)
        await waitUntil { await self.transcriber.bufferCount == 1 }
        clock.advance(by: .seconds(1))
    }

    func release() {
        releasedAt = clock.elapsed
        state.triggerReleased()
    }
}

@MainActor
private final class CueStateSpy: RecordingCuePresenting {
    private(set) var states: [RecordingCueState] = []

    func apply(_ state: RecordingCueState) {
        states.append(state)
    }

    func updateLevel(_ level: Double) {}

    func updateTranscript(_ text: String) {}
}

private let speech = -20.0
private let silence = -60.0

@MainActor
private func historyWithResult() -> HistoryStore {
    let history = HistoryStore()
    history.append(DictationRecord(
        id: UUID(), finishedAt: .now, transcript: "Original", output: "Previous result",
        transformation: .translation(targetLanguage: "English", toneInstruction: ""), outcome: .success
    ))
    return history
}

@MainActor
private func makeRecordingSettings() -> AppSettings {
    let suiteName = "SyrupReleasePathTests.\(UUID().uuidString)"
    let userDefaults = UserDefaults(suiteName: suiteName)!
    userDefaults.removePersistentDomain(forName: suiteName)
    let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
    settings.playSounds = false
    return settings
}

@MainActor
private func settle() async {
    for _ in 0..<100 {
        await Task.yield()
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: @MainActor () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
    #expect(await condition(), sourceLocation: sourceLocation)
}
