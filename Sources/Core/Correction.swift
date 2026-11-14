import Foundation

struct Correction: Codable, Equatable, Sendable {
    var heard: String
    var replacement: String

    private static let unspacedScript = try! NSRegularExpression(
        pattern: #"^[\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}\p{Thai}\p{Lao}\p{Khmer}\p{Myanmar}\p{Tibetan}]"#
    )

    static func apply(_ corrections: [Correction], to text: String) -> String {
        let selected = matches(corrections, in: text)
        guard !selected.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for candidate in selected.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            result += text[cursor..<candidate.range.lowerBound]
            result += corrections[candidate.rule].replacement
            cursor = candidate.range.upperBound
        }
        return result + text[cursor...]
    }

    /// How many replacements `apply` makes. Replacing a word with itself is not a fix.
    static func replacementCount(_ corrections: [Correction], in text: String) -> Int {
        matches(corrections, in: text).filter { text[$0.range] != corrections[$0.rule].replacement }.count
    }

    private static func matches(
        _ corrections: [Correction],
        in text: String
    ) -> [(range: Range<String.Index>, rule: Int, length: Int)] {
        guard !corrections.isEmpty else { return [] }
        var candidates: [(range: Range<String.Index>, rule: Int, length: Int)] = []
        for (index, correction) in corrections.enumerated() {
            let phrase = correction.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty else { continue }
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: phrase, options: .caseInsensitive, range: start..<text.endIndex) {
                let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
                let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
                let endsAtBoundary = !word(after) || possessiveSuffix(in: text, from: range.upperBound)
                if !(word(phrase.first) && word(before)) && (!word(phrase.last) || endsAtBoundary) {
                    candidates.append((range, index, text.distance(from: range.lowerBound, to: range.upperBound)))
                }
                start = text.index(after: range.lowerBound)
            }
        }
        candidates.sort {
            if $0.length != $1.length { return $0.length > $1.length }
            if $0.range.lowerBound != $1.range.lowerBound { return $0.range.lowerBound < $1.range.lowerBound }
            return $0.rule < $1.rule
        }
        var selected: [(range: Range<String.Index>, rule: Int, length: Int)] = []
        for candidate in candidates where !selected.contains(where: { $0.range.overlaps(candidate.range) }) {
            selected.append(candidate)
        }
        return selected
    }

    private static func possessiveSuffix(in text: String, from index: String.Index) -> Bool {
        guard index < text.endIndex, "'’".contains(text[index]) else { return false }
        let s = text.index(after: index)
        guard s < text.endIndex, text[s].lowercased() == "s" else { return false }
        let end = text.index(after: s)
        return end == text.endIndex || !word(text[end])
    }

    private static func word(_ character: Character?) -> Bool {
        guard let character else { return false }
        let text = String(character)
        if unspacedScript.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil { return false }
        return character.isLetter || character.isNumber || "_'’".contains(character)
            || character.unicodeScalars.contains { CharacterSet.nonBaseCharacters.contains($0) }
    }
}
