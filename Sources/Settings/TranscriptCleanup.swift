import Foundation

enum TranscriptCleanup {
    private enum Formatting {
        case line, paragraph, openQuote, closeQuote
        case symbol(Character, Join)
    }

    private enum Join { case next, both, previous }

    private struct Rules {
        let fillers: [String]
        let formatting: [(String, Formatting)]
    }

    private static let rules: [String: Rules] = [
        "en": Rules(fillers: ["um", "umm", "uh", "uhh", "erm", "er", "ah"], formatting: [
            ("new line", .line), ("line break", .line), ("new paragraph", .paragraph),
            ("open quote", .openQuote), ("close quote", .closeQuote),
            ("hashtag", .symbol("#", .next)), ("hash sign", .symbol("#", .next)),
            ("at sign", .symbol("@", .next)), ("underscore", .symbol("_", .both)),
            ("hyphen", .symbol("-", .both)), ("slash", .symbol("/", .both)),
            ("comma", .symbol(",", .previous)), ("semicolon", .symbol(";", .previous)),
            ("colon", .symbol(":", .previous)),
        ]),
        "pt": Rules(fillers: ["ahn", "hum", "hmm", "ãh"], formatting: [
            ("nova linha", .line), ("quebra de linha", .line), ("novo parágrafo", .paragraph),
            ("abre aspas", .openQuote), ("fecha aspas", .closeQuote),
            ("hashtag", .symbol("#", .next)), ("jogo da velha", .symbol("#", .next)),
            ("arroba", .symbol("@", .next)), ("sinal de arroba", .symbol("@", .next)),
            ("sublinhado", .symbol("_", .both)), ("underscore", .symbol("_", .both)),
            ("hífen", .symbol("-", .both)), ("barra", .symbol("/", .both)),
            ("vírgula", .symbol(",", .previous)), ("ponto e vírgula", .symbol(";", .previous)),
            ("dois pontos", .symbol(":", .previous)),
        ]),
    ]
    private static let word = #"[\p{L}\p{M}\p{N}_'’-]"#

    private static func isPadding(_ character: Character) -> Bool {
        "\t ,.\u{2026}".contains(character)
    }

    static func apply(_ text: String, localeID: String, cleanup: Bool = true, spokenSymbols: Bool = false) -> String {
        guard spokenSymbols else {
            return cleanup ? legacyCleanup(text, localeID: localeID) : text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return symbols(text, localeID: localeID, cleanup: cleanup)
    }

    private static func symbols(_ text: String, localeID: String, cleanup: Bool) -> String {
        let language = Locale(identifier: localeID).language.languageCode?.identifier ?? ""
        guard let rules = rules[language] else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalized = (cleanup ? legacyCleanup(text, localeID: localeID) : text).precomposedStringWithCanonicalMapping
        let formatting = rules.formatting.filter {
            if case .symbol = $0.1 { return true }
            return false
        }.sorted { $0.0.count > $1.0.count }
        let alternatives = formatting.map { "(" + NSRegularExpression.escapedPattern(for: $0.0) + ")" }.joined(separator: "|")
        let matcher = try! NSRegularExpression(pattern: "(?<!" + word + ")(?:" + alternatives + ")(?!" + word + ")", options: .caseInsensitive)
        var result = ""
        var cursor = normalized.startIndex
        var protectedBytes = 0
        for match in matcher.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            let range = Range(match.range, in: normalized)!
            result += normalized[cursor..<range.lowerBound]
            let rule = formatting[(1..<match.numberOfRanges).first { match.range(at: $0).location != NSNotFound }! - 1].1
            cursor = range.upperBound
            while cursor < normalized.endIndex, isPadding(normalized[cursor]) {
                cursor = normalized.index(after: cursor)
            }
            let next = cursor == normalized.endIndex ? nil : normalized[cursor]
            guard case .symbol(let symbol, let join) = rule else { continue }
            if join != .next {
                while result.utf8.count > protectedBytes,
                      let last = result.last, last == " " || last == "\t" || last == "," { result.removeLast() }
            }
            result.append(symbol)
            if join == .previous, let next, !next.isWhitespace, !next.isPunctuation { result += " " }
            protectedBytes = result.utf8.count - (result.last == " " ? 1 : 0)
        }
        result += normalized[cursor...]
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fillerRegex(_ rules: Rules) -> NSRegularExpression {
        let fillers = rules.fillers.flatMap { [$0, $0.prefix(1).uppercased() + $0.dropFirst()] }
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "(?<!" + word + ")(" + fillers + ")(?!" + word + #")(?:,|\.{3}|…)?[\t ]*"#)
    }

    /// How many filler words cleanup removes from this text.
    static func fillerCount(in text: String, localeID: String) -> Int {
        let language = Locale(identifier: localeID).language.languageCode?.identifier ?? ""
        guard let rules = rules[language] else { return 0 }
        let normalized = text.precomposedStringWithCanonicalMapping
        return fillerRegex(rules).numberOfMatches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized))
    }

    private static func legacyCleanup(_ text: String, localeID: String) -> String {
        let language = Locale(identifier: localeID).language.languageCode?.identifier ?? ""
        guard let rules = rules[language] else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result = text.precomposedStringWithCanonicalMapping
        for (phrase, formatting) in rules.formatting {
            if case .symbol = formatting { continue }
            let pattern = #"[\t ,.\u2026]*(?<!"# + word + ")" + NSRegularExpression.escapedPattern(for: phrase)
                + "(?!" + word + #")[\t ,.\u2026]*"#
            let regex = try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
            for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                let range = Range(match.range, in: result)!
                let replacement: String
                switch formatting {
                case .symbol: continue
                case .line: replacement = "\n"
                case .paragraph: replacement = "\n\n"
                case .openQuote:
                    let previous = result[..<range.lowerBound].last
                    replacement = (previous == nil || previous?.isWhitespace == true ? "" : " ") + "\""
                case .closeQuote:
                    let next = result[range.upperBound...].first
                    replacement = "\"" + (next == nil || next?.isWhitespace == true || next?.isPunctuation == true ? "" : " ")
                }
                result.replaceSubrange(range, with: replacement)
            }
        }
        let regex = fillerRegex(rules)
        while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) {
            let range = Range(match.range, in: result)!
            let token = Range(match.range(at: 1), in: result)!
            let prefix = result[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let sentenceStart = prefix.isEmpty || prefix.last == "\n" || prefix.last.map { ".!?".contains($0) } == true
            let capitalizesNext = result[token].first?.isUppercase == true && sentenceStart
            var before = String(result[..<range.lowerBound])
            var after = String(result[range.upperBound...])
            if after.first == "\n" {
                while before.last == " " || before.last == "\t" { before.removeLast() }
            }
            if capitalizesNext, let index = after.firstIndex(where: { !$0.isWhitespace }), after[index].isLetter {
                after.replaceSubrange(index..<after.index(after: index), with: after[index].uppercased())
            }
            result = before + after
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
