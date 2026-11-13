import Foundation
import NaturalLanguage

struct CaretContext: Equatable, Sendable {
    var precedingWordCharacter = false
    var continuesSentence = false
    var textFollows = false

    static func parse(before: String, after: String, hasSelection: Bool = false) -> Self {
        // Spacing deliberately keeps the original single-UTF-16-unit rule.
        let preceding = before.utf16.last.flatMap(UnicodeScalar.init).map(String.init) ?? ""
        let previous = before.last { $0 != " " && $0 != "\t" }
        let next = after.first { $0 != " " && $0 != "\t" }
        return Self(
            precedingWordCharacter: !hasSelection && DeliveryTarget.isWordCharacter(preceding),
            continuesSentence: previous.map { $0.isLetter || $0.isNumber || $0 == "," || $0 == ";" } ?? false,
            textFollows: next.map { $0.isLetter || $0.isNumber } ?? false
        )
    }
}

enum SentenceFit {
    private static let openingCharacters: Set<Character> = ["\"", "'", "“", "‘", "(", "[", "{", "«", "‹"]
    private static let abbreviations: Set<String> = [
        "etc", "vs", "dr", "dra", "mr", "mrs", "ms", "prof", "sr", "sra", "srta", "jr", "st", "ex", "p.ex"
    ]

    static func apply(_ text: String, context: CaretContext, protectedTerms: [String]) -> String {
        let cased = context.continuesSentence ? lowercaseFirstWord(text, protectedTerms: protectedTerms) : text
        return context.textFollows ? removingFinalPeriod(cased) : cased
    }

    static func lowercaseFirstWord(_ text: String, protectedTerms: [String]) -> String {
        guard let range = firstWordRange(in: text), let first = text[range].first else { return text }
        let word = String(text[range])
        let rest = word.dropFirst()
        guard first.isUppercase, word != "I", !word.hasPrefix("I'"), !word.hasPrefix("I’"),
              rest.allSatisfy({ ($0.isLetter && $0.isLowercase) || $0 == "'" || $0 == "’" }),
              !protectedTerms.contains(where: { !$0.isEmpty && text[range.lowerBound...].hasPrefix($0) }),
              !isName(text, at: range.lowerBound) else { return text }
        var result = text
        result.replaceSubrange(range.lowerBound..<text.index(after: range.lowerBound), with: String(first).lowercased())
        return result
    }

    static func firstWordIsComplete(in text: String, protectedTerms: [String]) -> Bool {
        guard let range = firstWordRange(in: text) else {
            return text.contains { !$0.isWhitespace && !openingCharacters.contains($0) }
        }
        let prefix = text[range.lowerBound...]
        if protectedTerms.contains(where: { $0.count > prefix.count && $0.hasPrefix(prefix) }) { return false }
        return range.upperBound != text.endIndex
    }

    static func removingFinalPeriod(_ text: String) -> String {
        guard let end = text.lastIndex(where: { !$0.isWhitespace }), text[end] == ".", end > text.startIndex else { return text }
        let previous = text.index(before: end)
        guard text[previous] != "." else { return text }
        let wordStart = text[..<end].lastIndex(where: { $0.isWhitespace || openingCharacters.contains($0) })
            .map { text.index(after: $0) } ?? text.startIndex
        let word = String(text[wordStart..<end])
        guard !word.contains("."), !abbreviations.contains(word.lowercased()) else { return text }
        var result = text
        result.remove(at: end)
        return result
    }

    // Retain the entire final token so abbreviation decisions never depend on already-posted text.
    static func finalWordStart(in text: String) -> String.Index {
        guard let end = text.lastIndex(where: { !$0.isWhitespace }) else { return text.startIndex }
        return text[...end].lastIndex(where: { $0.isWhitespace }).map { text.index(after: $0) } ?? text.startIndex
    }

    private static func firstWordRange(in text: String) -> Range<String.Index>? {
        guard let start = text.firstIndex(where: { !$0.isWhitespace && !openingCharacters.contains($0) }),
              text[start].isLetter else { return nil }
        let end = text[start...].firstIndex(where: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" && $0 != "-" }) ?? text.endIndex
        return start..<end
    }

    private static func isName(_ text: String, at index: String.Index) -> Bool {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let (tag, _) = tagger.tag(at: index, unit: .word, scheme: .nameType)
        return tag == .personalName || tag == .placeName || tag == .organizationName
    }
}
