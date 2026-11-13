import Foundation

enum ModelOutputNormalizer {
    static let quotePairs: [(opening: Character, closing: Character)] = [
        ("\"", "\""),
        ("'", "'"),
        ("“", "”"),
        ("‘", "’"),
    ]

    static func requestsQuotes(input: String, instruction: String) -> Bool {
        guard instruction.contains(PromptBuilder.spokenFormattingInstruction) else { return false }
        let foldedInput = input.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return foldedInput.range(of: #"\b(?:in\s+quotes|open\s+quotes?|close\s+quotes?|entre\s+aspas|abre\s+aspas|fecha\s+aspas)\b"#, options: .regularExpression) != nil
    }

    static func normalize(_ text: String, keepsWrapperQuotes: Bool = false) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keepsWrapperQuotes == false else { return trimmedText }
        guard let first = trimmedText.first, let last = trimmedText.last else {
            return trimmedText
        }

        guard quotePairs.contains(where: {
            $0.opening == first && $0.closing == last
        }) else {
            return trimmedText
        }

        let inner = trimmedText.dropFirst().dropLast()
        // A quote inside means these are two quoted phrases, not one wrapper.
        guard inner.contains(first) == false, inner.contains(last) == false else {
            return trimmedText
        }
        return String(inner).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func beginsWithPotentialWrapperQuote(_ text: String) -> Bool {
        guard let first = text.first(where: { $0.isWhitespace == false }) else {
            return false
        }
        return quotePairs.contains(where: { $0.opening == first })
    }

    static func holdbackStart(in text: String) -> String.Index? {
        guard text.count > 2 else { return nil }

        let twoCharacterTail = text.index(text.endIndex, offsetBy: -2)
        guard text.last?.isWhitespace == true,
              let lastNonWhitespace = text.lastIndex(where: { $0.isWhitespace == false }) else {
            return twoCharacterTail
        }

        return min(twoCharacterTail, lastNonWhitespace)
    }
}
