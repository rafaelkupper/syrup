import Foundation

struct GlossaryProposal: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var term: String
    var mishearings: [String]
    let confidence: Double
    let createdAt: Date
}

struct GlossaryProposalList: Equatable, Codable {
    static let currentVersion = 1
    /// Proposals wait for the person; past this many, new findings are dropped until they decide.
    static let maximumProposals = 50
    /// The oldest dismissals are forgotten past this many.
    static let maximumDismissedKeys = 500

    var version: Int = currentVersion
    var proposals: [GlossaryProposal] = []
    var dismissedKeys: [String] = []

    @discardableResult
    mutating func addIfNew(
        _ proposal: GlossaryProposal,
        existingGlossary: GlossaryList
    ) -> Bool {
        let normalizedTerm = proposal.term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedTerm.isEmpty == false else { return false }

        let key = normalizedTerm.lowercased()
        guard proposals.count < Self.maximumProposals,
              existingGlossary.terms.contains(where: { $0.term.lowercased() == key }) == false,
              proposals.contains(where: { $0.term.lowercased() == key }) == false,
              dismissedKeys.contains(key) == false else {
            return false
        }

        proposals.append(GlossaryProposal(
            id: proposal.id,
            term: normalizedTerm,
            mishearings: proposal.mishearings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false },
            confidence: proposal.confidence,
            createdAt: proposal.createdAt
        ))
        return true
    }

    mutating func removeProposal(id: UUID) {
        proposals.removeAll { $0.id == id }
    }

    mutating func dismiss(id: UUID) {
        guard let proposal = proposals.first(where: { $0.id == id }) else { return }
        let key = proposal.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        removeProposal(id: id)
        if key.isEmpty == false, dismissedKeys.contains(key) == false {
            dismissedKeys.append(key)
            dismissedKeys.removeFirst(max(0, dismissedKeys.count - Self.maximumDismissedKeys))
        }
    }
}
