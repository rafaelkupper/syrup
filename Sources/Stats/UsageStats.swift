import Foundation

/// Numbers only. No transcript, result, or workflow text ever reaches this type.
struct UsageStats: Codable, Equatable, Sendable {
    struct Sample: Codable, Equatable, Sendable {
        var words: Int
        var seconds: Double
    }

    static let recentSampleLimit = 100
    static let longestSampleSeconds = 400.0
    static let typingWordsPerMinute = 40.0

    var version = 1
    var totalWords = 0
    var totalFixes = 0
    var totalSpeechSeconds = 0.0
    /// Words per local calendar day, keyed yyyy-MM-dd.
    var wordsByDay: [String: Int] = [:]
    /// Words per app bundle identifier.
    var wordsByApp: [String: Int] = [:]
    var recentSamples: [Sample] = []

    var isEmpty: Bool { totalWords == 0 }

    mutating func record(
        words: Int,
        seconds: Double,
        fixes: Int,
        appBundleID: String?,
        now: Date,
        calendar: Calendar
    ) {
        guard words > 0 else { return }
        totalWords += words
        totalFixes += fixes
        totalSpeechSeconds += seconds
        wordsByDay[Self.dayKey(for: now, calendar: calendar), default: 0] += words
        if let appBundleID {
            wordsByApp[appBundleID, default: 0] += words
        }
        if seconds > 0, seconds < Self.longestSampleSeconds {
            recentSamples.append(Sample(words: words, seconds: seconds))
            if recentSamples.count > Self.recentSampleLimit {
                recentSamples.removeFirst(recentSamples.count - Self.recentSampleLimit)
            }
        }
    }

    /// Words over speaking time across recent dictations, so a long one counts for more than a short one.
    var wordsPerMinute: Int? {
        let seconds = recentSamples.reduce(0) { $0 + $1.seconds }
        guard seconds > 0 else { return nil }
        let words = recentSamples.reduce(0) { $0 + $1.words }
        return Int((Double(words) / seconds * 60).rounded())
    }

    /// Typing the same words at `typingWordsPerMinute`, minus the time spent speaking them.
    var timeSavedSeconds: Double {
        max(0, Double(totalWords) / Self.typingWordsPerMinute * 60 - totalSpeechSeconds)
    }

    func topApps(limit: Int) -> [(bundleID: String, words: Int)] {
        wordsByApp
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map { (bundleID: $0.key, words: $0.value) }
    }

    func currentStreak(today: Date, calendar: Calendar) -> Int {
        var day = calendar.startOfDay(for: today)
        if words(on: day, calendar: calendar) == 0 {
            // Today isn't over, so a streak through yesterday is still alive.
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while words(on: day, calendar: calendar) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    func longestStreak(calendar: Calendar) -> Int {
        let days = wordsByDay.filter { $0.value > 0 }.keys.compactMap { Self.date(fromDayKey: $0, calendar: calendar) }.sorted()
        var longest = 0
        var current = 0
        var previous: Date?
        for day in days {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                current += 1
            } else {
                current = 1
            }
            longest = max(longest, current)
            previous = day
        }
        return longest
    }

    func words(on day: Date, calendar: Calendar) -> Int {
        wordsByDay[Self.dayKey(for: day, calendar: calendar)] ?? 0
    }

    /// 0: none, 1: 1-249, 2: 250-499, 3: 500-749, 4: 750 or more.
    static func activityLevel(words: Int) -> Int {
        guard words > 0 else { return 0 }
        return min(words / 250 + 1, 4)
    }

    /// Whole Sunday-to-Saturday weeks, oldest first, ending with the week holding `today`.
    /// Days after today are nil.
    static func activityWeeks(count: Int, today: Date, calendar: Calendar) -> [[Date?]] {
        let today = calendar.startOfDay(for: today)
        let weekday = calendar.component(.weekday, from: today)
        guard let thisSunday = calendar.date(byAdding: .day, value: 1 - weekday, to: today) else { return [] }
        return (0..<count).reversed().map { weeksBack in
            (0..<7).map { offset -> Date? in
                guard let day = calendar.date(byAdding: .day, value: offset - weeksBack * 7, to: thisSunday),
                      day <= today else { return nil }
                return day
            }
        }
    }

    static func wordCount(in text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
