import Foundation

/// Reveals arriving transcript chunks progressively so the cue reads like
/// continuous typing instead of popping a phrase at a time. When a volatile
/// refinement rewrites earlier words, the display snaps back to the common
/// prefix in one step and retypes from there.
struct TranscriptTypewriter: Sendable {
    private(set) var displayed: String = ""
    var target: String = ""

    /// Advances the displayed text one animation step toward the target.
    /// Returns true while more steps are needed.
    mutating func advance() -> Bool {
        guard displayed != target else { return false }

        guard target.hasPrefix(displayed) else {
            displayed = String(commonPrefix(displayed, target))
            return true
        }

        let remaining = target.count - displayed.count
        let step = max(2, remaining / 6)
        displayed = String(target.prefix(displayed.count + step))
        return displayed != target
    }

    mutating func reset() {
        displayed = ""
        target = ""
    }

    private func commonPrefix(_ lhs: String, _ rhs: String) -> Substring {
        var index = lhs.startIndex
        var otherIndex = rhs.startIndex
        while index < lhs.endIndex,
              otherIndex < rhs.endIndex,
              lhs[index] == rhs[otherIndex] {
            index = lhs.index(after: index)
            otherIndex = rhs.index(after: otherIndex)
        }
        return lhs[..<index]
    }
}
