import Testing
@testable import Syrup

@MainActor
struct RecordingDurationDetentsTests {
    @Test
    func detentsSpanTheAllowedRangeInAscendingOrder() {
        #expect(RecordingDurationDetents.seconds.first == AppSettings.minimumRecordingDurationSeconds)
        #expect(RecordingDurationDetents.seconds.last == AppSettings.maximumRecordingDurationSecondsLimit)
        #expect(RecordingDurationDetents.seconds == RecordingDurationDetents.seconds.sorted())
        #expect(Set(RecordingDurationDetents.seconds).count == RecordingDurationDetents.seconds.count)
    }

    @Test
    func nearestIndexSnapsToTheClosestDetent() {
        #expect(RecordingDurationDetents.nearestIndex(to: 1) == 0)
        #expect(RecordingDurationDetents.nearestIndex(to: 120) == 9)
        #expect(RecordingDurationDetents.nearestIndex(to: 47) == 6)
        #expect(RecordingDurationDetents.nearestIndex(to: 3_600) == 17)
        #expect(RecordingDurationDetents.nearestIndex(to: 10_000) == 17)
        #expect(RecordingDurationDetents.nearestIndex(to: 0) == 0)
    }

    @Test
    func labelsAreRoundAndReadable() {
        #expect(RecordingDurationDetents.label(for: 1) == "1 sec")
        #expect(RecordingDurationDetents.label(for: 45) == "45 sec")
        #expect(RecordingDurationDetents.label(for: 60) == "1 min")
        #expect(RecordingDurationDetents.label(for: 90) == "1m 30s")
        #expect(RecordingDurationDetents.label(for: 120) == "2 min")
        #expect(RecordingDurationDetents.label(for: 2_700) == "45 min")
        #expect(RecordingDurationDetents.label(for: 3_600) == "1 hour")
    }
}
