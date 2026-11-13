import Foundation
import Testing
@testable import Syrup

struct GlossaryProposalTests {
    @Test
    func addIfNewNormalizesAndDeduplicatesAcrossAllSources() {
        let existingGlossary = GlossaryList(terms: [GlossaryTerm(term: "Kubernetes")])
        var list = GlossaryProposalList(dismissedKeys: ["codex"])
        let first = proposal(term: "  Syrup  ", mishearings: [" sirup ", " "])

        let addedFirst = list.addIfNew(first, existingGlossary: existingGlossary)
        #expect(addedFirst)
        #expect(list.proposals.map(\.term) == ["Syrup"])
        #expect(list.proposals.first?.mishearings == ["sirup"])
        let addedOpenDuplicate = list.addIfNew(
            proposal(term: "sYrUp"),
            existingGlossary: existingGlossary
        )
        let addedGlossaryDuplicate = list.addIfNew(
            proposal(term: "kubernetes"),
            existingGlossary: existingGlossary
        )
        let addedDismissed = list.addIfNew(
            proposal(term: "CODEX"),
            existingGlossary: existingGlossary
        )
        let addedEmpty = list.addIfNew(
            proposal(term: "  "),
            existingGlossary: existingGlossary
        )
        #expect(addedOpenDuplicate == false)
        #expect(addedGlossaryDuplicate == false)
        #expect(addedDismissed == false)
        #expect(addedEmpty == false)
    }

    @Test
    func removeProposalRemovesOnlyMatchingID() {
        let kept = proposal(term: "WhisperKit")
        let removed = proposal(term: "Syrup")
        var list = GlossaryProposalList(proposals: [kept, removed])

        list.removeProposal(id: removed.id)

        #expect(list.proposals == [kept])
    }

    @Test
    func dismissRemovesProposalAndRecordsPermanentKey() {
        let dismissed = proposal(term: " Syrup ")
        var list = GlossaryProposalList(proposals: [dismissed])

        list.dismiss(id: dismissed.id)

        #expect(list.proposals.isEmpty)
        #expect(list.dismissedKeys == ["syrup"])
        let addedDismissed = list.addIfNew(
            proposal(term: "SYRUP"),
            existingGlossary: GlossaryList()
        )
        #expect(addedDismissed == false)
    }

    @Test
    func codableRoundTripPreservesProposalList() throws {
        let list = GlossaryProposalList(
            proposals: [proposal(term: "Syrup", mishearings: ["sirup"])],
            dismissedKeys: ["codex"]
        )

        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(GlossaryProposalList.self, from: data)

        #expect(decoded == list)
    }

    private func proposal(
        term: String,
        mishearings: [String] = ["misheard"]
    ) -> GlossaryProposal {
        GlossaryProposal(
            id: UUID(),
            term: term,
            mishearings: mishearings,
            confidence: 0.8,
            createdAt: Date(timeIntervalSince1970: 123)
        )
    }
}
