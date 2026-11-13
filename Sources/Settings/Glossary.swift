import Foundation

struct GlossaryTerm: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var term: String
    var mishearings: [String]

    init(id: UUID = UUID(), term: String, mishearings: [String] = []) {
        self.id = id
        self.term = term
        self.mishearings = mishearings
    }

    fileprivate var normalized: GlossaryTerm? {
        let normalizedTerm = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTerm.isEmpty == false else { return nil }

        return GlossaryTerm(
            id: id,
            term: normalizedTerm,
            mishearings: mishearings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        )
    }
}

struct GlossaryList: Equatable, Codable {
    enum Validation: Equatable {
        case valid
        case empty
        case duplicate
    }

    static let currentVersion = 1

    var version: Int
    var terms: [GlossaryTerm]

    init(version: Int = currentVersion, terms: [GlossaryTerm] = []) {
        self.version = version
        self.terms = Self.normalize(terms)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        terms = Self.normalize(try container.decode([GlossaryTerm].self, forKey: .terms))
    }

    @discardableResult
    mutating func append(_ term: GlossaryTerm) -> Bool {
        let previousCount = terms.count
        terms = Self.normalize(terms + [term])
        return terms.count > previousCount
    }

    mutating func update(
        id: UUID,
        term: String,
        mishearings: [String]
    ) {
        guard let index = terms.firstIndex(where: { $0.id == id }) else { return }
        terms[index].term = term
        terms[index].mishearings = mishearings
        terms = Self.normalize(terms)
    }

    mutating func remove(id: UUID) {
        terms.removeAll { $0.id == id }
    }

    func validation(for candidate: String, excluding excludedID: UUID? = nil) -> Validation {
        let normalizedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedCandidate.isEmpty == false else { return .empty }

        let comparisonKey = normalizedCandidate.lowercased()
        let isDuplicate = terms.contains { term in
            if let excludedID, term.id == excludedID {
                return false
            }
            return term.term.lowercased() == comparisonKey
        }
        return isDuplicate ? .duplicate : .valid
    }

    private static func normalize(_ terms: [GlossaryTerm]) -> [GlossaryTerm] {
        var seenTerms: Set<String> = []

        return terms.compactMap { term in
            guard let normalized = term.normalized else { return nil }
            let comparisonKey = normalized.term.lowercased()
            guard seenTerms.insert(comparisonKey).inserted else { return nil }
            return normalized
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case terms
    }
}
