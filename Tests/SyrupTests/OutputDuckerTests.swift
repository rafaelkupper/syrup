import Foundation
import Synchronization
import Testing
@testable import Syrup

struct OutputDuckerTests {
    @Test
    func loweringTwiceRestoresOriginalLevelsExactly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = fixture.controller.current()
        try await fixture.ducker.lower()
        #expect(fixture.controller.current()?.channels == [1: 0.24000001, 2: 0.120000005])
        try await fixture.ducker.lower()
        #expect(fixture.controller.current()?.channels == [1: 0.24000001, 2: 0.120000005])
        try await fixture.ducker.restore()
        #expect(fixture.controller.current() == original)
        #expect(fixture.defaults.dictionary(forKey: "outputVolumeRestore") == nil)
    }

    @Test
    func restoreWithoutLoweringDoesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = fixture.controller.current()
        try await fixture.ducker.restore()
        #expect(fixture.controller.current() == original)
        #expect(fixture.controller.writeCount == 0)
    }

    @Test
    func userChangesSurviveRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.ducker.lower()
        fixture.controller.change("speakers", channels: [1: 0.55, 2: 0.55])
        try await fixture.ducker.restore()
        #expect(fixture.controller.current()?.channels == [1: 0.55, 2: 0.55])
        #expect(fixture.defaults.dictionary(forKey: "outputVolumeRestore") == nil)
    }

    @Test
    func restoresWhenTheDeviceRoundsTheLoweredLevel() async throws {
        let fixture = try Fixture(channels: [0: 0.7012586])
        defer { fixture.cleanUp() }
        try await fixture.ducker.lower()
        fixture.controller.change("speakers", channels: [0: 0.21037757])
        try await fixture.ducker.restore()
        #expect(fixture.controller.current()?.channels == [0: 0.7012586])
    }

    @Test
    func theSmallestKeyboardVolumeStepCountsAsAUserChange() async throws {
        let fixture = try Fixture(channels: [0: 0.8])
        defer { fixture.cleanUp() }
        try await fixture.ducker.lower()
        let changed = try #require(fixture.controller.current()?.channels[0]) + 1.0 / 64
        fixture.controller.change("speakers", channels: [0: changed])
        try await fixture.ducker.restore()
        #expect(fixture.controller.current()?.channels == [0: changed])
    }

    @Test
    func aChangedChannelIsPreservedWhileOtherChannelRestores() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.ducker.lower()
        fixture.controller.change("speakers", channels: [1: 0.55])
        try await fixture.ducker.restore()
        #expect(fixture.controller.current()?.channels == [1: 0.55, 2: 0.4])
    }

    @Test
    func devicesWithoutSettableVolumeAreSilentNoOps() async throws {
        let fixture = try Fixture(channels: [:])
        defer { fixture.cleanUp() }
        try await fixture.ducker.lower()
        try await fixture.ducker.restore()
        #expect(fixture.controller.writeCount == 0)
        #expect(fixture.defaults.object(forKey: "outputVolumeRestore") == nil)
    }

    @Test
    func crashRecoveryRestoresRecordedDeviceDespiteDefaultChangeAndRunsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = fixture.controller.current()
        try await fixture.ducker.lower()
        fixture.controller.change("headphones", channels: [0: 0.9])
        fixture.controller.selectDefault("headphones")
        let recovered = OutputDucker(controller: fixture.controller, defaultsSuiteName: fixture.suite)
        try await recovered.restoreAfterCrash()
        #expect(fixture.controller.current("speakers") == original)
        #expect(fixture.controller.current("headphones")?.channels == [0: 0.9])
        fixture.controller.change("speakers", channels: [1: 0.7])
        try await recovered.restoreAfterCrash()
        #expect(fixture.controller.current("speakers")?.channels[1] == 0.7)
        #expect(fixture.defaults.object(forKey: "outputVolumeRestore") == nil)
    }

    @Test
    func crashRecoveryPreservesUserVolumeChange() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.ducker.lower()
        fixture.controller.change("speakers", channels: [1: 0.9, 2: 0.9])
        let recovered = OutputDucker(controller: fixture.controller, defaultsSuiteName: fixture.suite)
        try await recovered.restoreAfterCrash()
        #expect(fixture.controller.current()?.channels == [1: 0.9, 2: 0.9])
    }

    @Test
    func missingRecordedDeviceClearsRecoveryRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.ducker.lower()
        fixture.controller.remove("speakers")
        let recovered = OutputDucker(controller: fixture.controller, defaultsSuiteName: fixture.suite)
        try await recovered.restoreAfterCrash()
        #expect(fixture.defaults.object(forKey: "outputVolumeRestore") == nil)
        #expect(fixture.controller.writeCount == 1)
    }

    @Test
    func savesOriginalAndLoweredValuesBeforeTouchingVolume() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.controller.beforeWrite.withLock { callback in
            callback = { [suite = fixture.suite] in
                let saved = UserDefaults(suiteName: suite)?.dictionary(forKey: "outputVolumeRestore")
                #expect(saved?["deviceUID"] as? String == "speakers")
                #expect((saved?["original"] as? [String: Float32]) == ["1": 0.8, "2": 0.4])
                #expect((saved?["lowered"] as? [String: Float32]) == ["1": 0.24000001, "2": 0.120000005])
            }
        }
        try await fixture.ducker.lower()
        fixture.controller.beforeWrite.withLock { $0 = nil }
        try await fixture.ducker.restore()
    }

    @Test
    func virtualMainVolumeAndZeroVolumeRestore() async throws {
        for level: Float32 in [0, 0.75] {
            let fixture = try Fixture(channels: [0: level])
            defer { fixture.cleanUp() }
            try await fixture.ducker.lower()
            #expect(fixture.controller.current()?.channels == [0: level == 0 ? 0 : 0.22500001])
            try await fixture.ducker.restore()
            #expect(fixture.controller.current()?.channels == [0: level])
        }
    }

    @Test
    func partiallyFailedLowerRestoresChangedChannel() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = fixture.controller.current()
        fixture.controller.failNextWrite()
        await #expect(throws: OutputVolumeError.self) { try await fixture.ducker.lower() }
        #expect(fixture.controller.current() == original)
        #expect(fixture.defaults.object(forKey: "outputVolumeRestore") == nil)
    }

    @Test
    func recoveryAfterCrashBeforeLoweringLeavesOriginalVolumeAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set([
            "deviceUID": "speakers",
            "original": ["1": Float32(0.8), "2": Float32(0.4)],
            "lowered": ["1": Float32(0.24000001), "2": Float32(0.120000005)]
        ], forKey: "outputVolumeRestore")
        try await fixture.ducker.restoreAfterCrash()
        #expect(fixture.controller.current()?.channels == [1: 0.8, 2: 0.4])
        #expect(fixture.controller.writeCount == 0)
        #expect(fixture.defaults.object(forKey: "outputVolumeRestore") == nil)
    }

    @Test
    func failedRestoreRetainsRecordForRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try await fixture.ducker.lower()
        fixture.controller.failNextWrite()
        await #expect(throws: OutputVolumeError.self) { try await fixture.ducker.restore() }
        #expect(fixture.defaults.object(forKey: "outputVolumeRestore") != nil)
        try await fixture.ducker.restoreAfterCrash()
        #expect(fixture.controller.current()?.channels == [1: 0.8, 2: 0.4])
        #expect(fixture.defaults.object(forKey: "outputVolumeRestore") == nil)
    }

    private struct Fixture {
        let suite = testDomainName("SyrupOutputDuckerTests")
        let defaults: UserDefaults
        let controller: FakeOutputVolumeController
        let ducker: OutputDucker

        init(channels: [UInt32: Float32] = [1: 0.8, 2: 0.4]) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            controller = FakeOutputVolumeController(channels: channels)
            ducker = OutputDucker(controller: controller, defaultsSuiteName: suite)
        }
        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }
}

private final class FakeOutputVolumeController: OutputVolumeControlling {
    struct State {
        var defaultUID = "speakers"
        var volumes: [String: [UInt32: Float32]]
        var writeCount = 0
        var failNextWrite = false
    }
    let state: Mutex<State>
    let beforeWrite = Mutex<(@Sendable () -> Void)?>(nil)
    var writeCount: Int { state.withLock { $0.writeCount } }

    init(channels: [UInt32: Float32]) {
        state = Mutex(State(volumes: ["speakers": channels]))
    }
    func current(_ uid: String? = nil) -> OutputVolume? {
        state.withLock { state in
            let uid = uid ?? state.defaultUID
            guard let channels = state.volumes[uid], channels.isEmpty == false else { return nil }
            return OutputVolume(deviceUID: uid, channels: channels)
        }
    }
    func defaultOutputVolume() -> OutputVolume? { current() }
    func volume(for deviceUID: String) -> OutputVolume? { current(deviceUID) }
    func setVolume(_ volume: OutputVolume) throws {
        beforeWrite.withLock { $0?() }
        try state.withLock { state in
            state.writeCount += 1
            let fail = state.failNextWrite
            state.failNextWrite = false
            for (channel, value) in volume.channels.sorted(by: { $0.key < $1.key }) {
                state.volumes[volume.deviceUID, default: [:]][channel] = value
                if fail { throw OutputVolumeError.writeFailed(-1) }
            }
        }
    }
    func failNextWrite() { state.withLock { $0.failNextWrite = true } }
    func change(_ uid: String, channels: [UInt32: Float32]) {
        state.withLock { $0.volumes[uid, default: [:]].merge(channels) { _, new in new } }
    }
    func selectDefault(_ uid: String) { state.withLock { $0.defaultUID = uid } }
    func remove(_ uid: String) { state.withLock { $0.volumes[uid] = nil } }
}
