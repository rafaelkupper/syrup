import SwiftUI

struct HomeStatsSection: View {
    let stats: UsageStats
    private static let weeksShown = 26
    private static let appsShown = 4
    private static let cell: CGFloat = 10
    private static let gap: CGFloat = 3
    @State private var hoveredDay: Date?

    /// The grid always runs Sunday to Saturday, whatever week the system starts on.
    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 1
        return calendar
    }

    var body: some View {
        Section {
            if stats.isEmpty {
                Text("Words, speed, and streaks appear after your first dictation.")
                    .foregroundStyle(.secondary)
            } else {
                figures
                activity
            }
        } header: {
            HStack {
                Text("Your dictation")
                Spacer()
                Text("Counts only, kept on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var figures: some View {
        HStack(spacing: 0) {
            figure(stats.wordsPerMinute.map { $0.formatted() } ?? "–", "words per minute")
            Divider()
            figure(stats.totalWords.formatted(), "words dictated")
            Divider()
            figure(Self.durationText(stats.timeSavedSeconds), "saved vs typing at \(Int(UsageStats.typingWordsPerMinute)) wpm")
            Divider()
            figure(stats.totalFixes.formatted(), "fillers and terms fixed")
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
    }

    private var activity: some View {
        let weeks = UsageStats.activityWeeks(count: Self.weeksShown, today: .now, calendar: calendar)
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                heatmap(weeks)
                monthLabels(weeks)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .fixedSize()

            if stats.wordsByApp.isEmpty == false {
                appBreakdown
            }
        }
        .padding(.vertical, 4)
    }

    private var caption: String {
        if let day = hoveredDay {
            let words = stats.words(on: day, calendar: calendar)
            return "\(day.formatted(.dateTime.weekday(.abbreviated).month().day())): \(words.formatted()) words"
        }
        let current = stats.currentStreak(today: .now, calendar: calendar)
        let longest = stats.longestStreak(calendar: calendar)
        let longestText = "longest \(Self.days(longest))"
        return current == 0 ? "No current streak, \(longestText)" : "\(current)-day streak, \(longestText)"
    }

    private func heatmap(_ weeks: [[Date?]]) -> some View {
        let size = CGSize(
            width: CGFloat(weeks.count) * (Self.cell + Self.gap) - Self.gap,
            height: 7 * (Self.cell + Self.gap) - Self.gap
        )
        let levels = weeks.map { week in
            week.map { day in day.map { UsageStats.activityLevel(words: stats.words(on: $0, calendar: calendar)) } }
        }
        let today = calendar.startOfDay(for: .now)
        return Canvas { context, _ in
            for (column, week) in levels.enumerated() {
                for (row, level) in week.enumerated() {
                    guard let level else { continue }
                    let rect = CGRect(
                        x: CGFloat(column) * (Self.cell + Self.gap),
                        y: CGFloat(row) * (Self.cell + Self.gap),
                        width: Self.cell,
                        height: Self.cell
                    )
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    let shading: GraphicsContext.Shading = level == 0
                        ? .color(.secondary.opacity(0.15))
                        : .color(.accentColor.opacity(0.25 * Double(level)))
                    context.fill(path, with: shading)
                    if let day = weeks[column][row], calendar.isDate(day, inSameDayAs: today) {
                        context.stroke(path, with: .color(.primary), lineWidth: 1.5)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let column = Int(point.x / (Self.cell + Self.gap))
                let row = Int(point.y / (Self.cell + Self.gap))
                hoveredDay = weeks.indices.contains(column) && (0..<7).contains(row) ? weeks[column][row] : nil
            case .ended:
                hoveredDay = nil
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Activity, last \(Self.weeksShown) weeks")
        .accessibilityValue(activitySummary(weeks))
    }

    private func monthLabels(_ weeks: [[Date?]]) -> some View {
        let starts: [(column: Int, name: String)] = weeks.enumerated().compactMap { column, week in
            guard let first = week.compactMap({ $0 }).first else { return nil }
            let month = calendar.component(.month, from: first)
            let previous = column > 0 ? weeks[column - 1].compactMap({ $0 }).first.map { calendar.component(.month, from: $0) } : nil
            guard month != previous else { return nil }
            return (column, first.formatted(.dateTime.month(.abbreviated)))
        }
        return ZStack(alignment: .topLeading) {
            ForEach(starts, id: \.column) { start in
                Text(start.name)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .offset(x: CGFloat(start.column) * (Self.cell + Self.gap))
            }
        }
        .frame(width: CGFloat(weeks.count) * (Self.cell + Self.gap), height: 12, alignment: .topLeading)
        .accessibilityHidden(true)
    }

    private func activitySummary(_ weeks: [[Date?]]) -> String {
        let days = weeks.flatMap { $0 }.compactMap { $0 }
        let active = days.filter { stats.words(on: $0, calendar: calendar) > 0 }.count
        return "Dictated on \(active) of \(days.count) days. \(caption)."
    }

    private var appBreakdown: some View {
        let apps = stats.topApps(limit: Self.appsShown)
        let most = Double(apps.first?.words ?? 1)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(apps, id: \.bundleID) { app in
                HStack(spacing: 8) {
                    AppIcon(bundleID: app.bundleID, size: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(AppInfoCache.name(for: app.bundleID))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(app.words.formatted())
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geometry in
                            Capsule()
                                .fill(Color.accentColor.opacity(0.8))
                                .frame(width: max(3, geometry.size.width * Double(app.words) / most))
                        }
                        .frame(height: 4)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(AppInfoCache.name(for: app.bundleID)), \(app.words.formatted()) words")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }

    static func durationText(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "\(hours) h" : "\(hours) h \(minutes % 60) min"
    }
}
