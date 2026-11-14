import Foundation
import Testing
@testable import Syrup

struct UsageStatsTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo")!
        calendar.firstWeekday = 1
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func record(_ stats: inout UsageStats, words: Int = 10, seconds: Double = 5, fixes: Int = 0, app: String? = nil, on day: Date) {
        stats.record(words: words, seconds: seconds, fixes: fixes, appBundleID: app, now: day, calendar: calendar)
    }

    @Test func totalsAccumulateAndEmptyTranscriptsDoNot() {
        var stats = UsageStats()
        record(&stats, words: 30, seconds: 10, fixes: 2, app: "com.a", on: date(2026, 11, 2))
        record(&stats, words: 0, seconds: 10, fixes: 5, app: "com.b", on: date(2026, 11, 2))
        record(&stats, words: 20, seconds: 5, fixes: 1, app: "com.a", on: date(2026, 11, 2))
        #expect(stats.totalWords == 50)
        #expect(stats.totalFixes == 3)
        #expect(stats.totalSpeechSeconds == 15)
        #expect(stats.wordsByApp == ["com.a": 50])
        #expect(stats.wordsByDay == ["2026-11-02": 50])
    }

    @Test func wordsPerMinuteUsesOnlyTheLast100ShortDictations() {
        var stats = UsageStats()
        #expect(stats.wordsPerMinute == nil)
        record(&stats, words: 10_000, seconds: 400, on: date(2026, 11, 2))
        #expect(stats.wordsPerMinute == nil)
        #expect(stats.totalWords == 10_000)
        record(&stats, words: 1_000, seconds: 1, on: date(2026, 11, 2))
        for _ in 0..<UsageStats.recentSampleLimit {
            record(&stats, words: 100, seconds: 60, on: date(2026, 11, 2))
        }
        #expect(stats.recentSamples.count == UsageStats.recentSampleLimit)
        #expect(stats.wordsPerMinute == 100)
    }

    @Test func timeSavedComparesWithTypingAndNeverGoesNegative() {
        var stats = UsageStats()
        record(&stats, words: 400, seconds: 120, on: date(2026, 11, 2))
        #expect(stats.timeSavedSeconds == 480)
        record(&stats, words: 1, seconds: 10_000, on: date(2026, 11, 2))
        #expect(stats.timeSavedSeconds == 0)
    }

    @Test func topAppsSortByWordsThenName() {
        var stats = UsageStats()
        record(&stats, words: 5, app: "com.b", on: date(2026, 11, 2))
        record(&stats, words: 5, app: "com.a", on: date(2026, 11, 2))
        record(&stats, words: 9, app: "com.c", on: date(2026, 11, 2))
        #expect(stats.topApps(limit: 2).map(\.bundleID) == ["com.c", "com.a"])
    }

    @Test(arguments: [(0, 0), (1, 1), (249, 1), (250, 2), (499, 2), (500, 3), (749, 3), (750, 4), (9_000, 4)])
    func activityLevelsMatchTheBands(words: Int, level: Int) {
        #expect(UsageStats.activityLevel(words: words) == level)
    }

    @Test func streaksCountCalendarDaysAndSurviveAnUnfinishedToday() {
        var stats = UsageStats()
        for day in [1, 2, 3, 6, 7] {
            record(&stats, on: date(2026, 10, day))
        }
        #expect(stats.longestStreak(calendar: calendar) == 3)
        #expect(stats.currentStreak(today: date(2026, 10, 7), calendar: calendar) == 2)
        #expect(stats.currentStreak(today: date(2026, 10, 8), calendar: calendar) == 2)
        #expect(stats.currentStreak(today: date(2026, 10, 9), calendar: calendar) == 0)
    }

    @Test func streaksCrossMonthAndYearEnds() {
        var stats = UsageStats()
        for day in [date(2025, 12, 31), date(2026, 1, 1)] {
            record(&stats, on: day)
        }
        #expect(stats.longestStreak(calendar: calendar) == 2)
        #expect(stats.currentStreak(today: date(2026, 1, 1), calendar: calendar) == 2)
    }

    @Test func dayKeyUsesTheLocalDayNotUTC() {
        let lateEvening = date(2026, 11, 2, hour: 23)
        #expect(UsageStats.dayKey(for: lateEvening, calendar: calendar) == "2026-11-02")
    }

    @Test func weeksRunSundayToSaturdayAndStopAtToday() throws {
        let tuesday = date(2026, 11, 3)
        let weeks = UsageStats.activityWeeks(count: 3, today: tuesday, calendar: calendar)
        #expect(weeks.count == 3)
        #expect(weeks.allSatisfy { $0.count == 7 })
        let first = try #require(weeks[0][0])
        #expect(calendar.component(.weekday, from: first) == 1)
        let last = weeks[2]
        #expect(last[2].map { UsageStats.dayKey(for: $0, calendar: calendar) } == "2026-11-03")
        #expect(last[3] == nil)
    }

    @Test(arguments: [("", 0), ("one", 1), ("let's meet at 4", 4), ("às 3, não, às 4.", 5)])
    func wordCounts(text: String, count: Int) {
        #expect(UsageStats.wordCount(in: text) == count)
    }

    @Test func encodedStatsCarryNoTextFields() throws {
        var stats = UsageStats()
        record(&stats, words: 3, app: "com.a", on: date(2026, 11, 2))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(stats)) as? [String: Any])
        #expect(Set(object.keys) == ["version", "totalWords", "totalFixes", "totalSpeechSeconds", "wordsByDay", "wordsByApp", "recentSamples"])
    }

    @Test func fixCountsMatchWhatCleanupAndCorrectionsDo() {
        #expect(TranscriptCleanup.fillerCount(in: "um so uh yes", localeID: "en-US") == 2)
        #expect(TranscriptCleanup.fillerCount(in: "umbrella", localeID: "en-US") == 0)
        #expect(TranscriptCleanup.fillerCount(in: "ok", localeID: "ja-JP") == 0)
        let corrections = [Correction(heard: "cooper netties", replacement: "Kubernetes")]
        #expect(Correction.replacementCount(corrections, in: "run cooper netties and cooper netties") == 2)
        #expect(Correction.apply(corrections, to: "run cooper netties") == "run Kubernetes")
        #expect(Correction.replacementCount(corrections, in: "nothing here") == 0)
    }
}

@MainActor
struct UsageStatsStoreTests {
    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "UsageStatsStoreTests-\(UUID())", directoryHint: .isDirectory)
            .appending(path: "usage-stats.json")
    }

    @Test func survivesARestartWithAPrivateFileAndDeletes() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = UsageStatsStore(fileURL: url)
        store.record(words: 12, seconds: 6, fixes: 1, appBundleID: "com.a")
        await store.flush()

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(UsageStatsStore(fileURL: url).stats == store.stats)

        await store.deleteAll()
        #expect(store.stats.isEmpty)
        await store.flush()
        #expect(UsageStatsStore(fileURL: url).stats.isEmpty)
    }

    @Test func aDeleteAfterManyWritesAlwaysLandsLast() async {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = UsageStatsStore(fileURL: url)
        for index in 0..<50 {
            store.record(words: index, seconds: 1, fixes: 0, appBundleID: "com.a")
        }
        await store.deleteAll()
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) == false)
        #expect(UsageStatsStore(fileURL: url).stats.isEmpty)
    }

    @Test func aFailedDeleteShowsTheStatsStillOnDiskAndSaysSo() async throws {
        let url = temporaryFile()
        let directory = url.deletingLastPathComponent().path(percentEncoded: false)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
            try? FileManager.default.removeItem(atPath: directory)
        }
        let store = UsageStatsStore(fileURL: url)
        store.record(words: 7, seconds: 3, fixes: 0, appBundleID: "com.a")
        await store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory)

        let deleted = await store.deleteAll()

        #expect(deleted == false)
        #expect(store.stats.isEmpty == false)
        #expect(store.stats == UsageStatsStore(fileURL: url).stats)
        #expect(store.deletionError != nil)
    }

    @Test func aDamagedFileStartsEmptyInsteadOfFailing() throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        #expect(UsageStatsStore(fileURL: url).stats.isEmpty)
    }
}
