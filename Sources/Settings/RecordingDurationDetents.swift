import Foundation

/// Non-linear scale for the maximum-recording slider: curated detents give
/// fine control on short durations while keeping the long end reachable.
enum RecordingDurationDetents {
    static let seconds: [Int] = [
        1, 2, 5, 10, 15, 30, 45,
        60, 90, 120, 180, 300,
        600, 900, 1_200, 1_800, 2_700, 3_600,
    ]

    struct ScaleMark: Identifiable {
        let label: String
        let fraction: Double
        var id: String { label }
    }

    static let scaleMarks: [ScaleMark] = [
        ScaleMark(label: "1s", fraction: fraction(ofIndex: 0)),
        ScaleMark(label: "1m", fraction: fraction(ofIndex: 7)),
        ScaleMark(label: "10m", fraction: fraction(ofIndex: 12)),
        ScaleMark(label: "1h", fraction: fraction(ofIndex: 17)),
    ]

    static func nearestIndex(to duration: Int) -> Int {
        seconds.indices.min {
            abs(seconds[$0] - duration) < abs(seconds[$1] - duration)
        } ?? 0
    }

    static func label(for duration: Int) -> String {
        guard duration >= 60 else {
            return "\(duration) sec"
        }
        guard duration < 3_600 else {
            return "1 hour"
        }
        let minutes = duration / 60
        let remainder = duration % 60
        return remainder == 0 ? "\(minutes) min" : "\(minutes)m \(remainder)s"
    }

    private static func fraction(ofIndex index: Int) -> Double {
        Double(index) / Double(seconds.count - 1)
    }
}
