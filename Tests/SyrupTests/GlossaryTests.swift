import Foundation
import Testing
@testable import Syrup

@MainActor
struct GlossaryTests {
    @Test
    func exportDocumentProducesDecodableGlossaryJSON() throws {
        let glossary = GlossaryList(terms: [
            GlossaryTerm(term: "Syrup", mishearings: ["sirup"]),
        ])
        let document = GlossaryExportDocument(glossary: glossary)

        let data = try document.encodedData()
        let decoded = try JSONDecoder().decode(GlossaryList.self, from: data)

        #expect(decoded == glossary)
    }

    @Test
    func composedSpeechVocabularyPrioritizesUserTermsAtTheCap() {
        let userTerms = (0...100).map { GlossaryTerm(term: "User term \($0)") }
        let glossary = GlossaryList(terms: userTerms)

        let vocabulary = AppSettings.composedSpeechVocabulary(
            glossary: glossary,
            includeCommonTechTerms: true
        )

        #expect(vocabulary == userTerms.prefix(100).map(\.term))
        #expect(vocabulary.count == PromptBuilder.maximumGlossaryTerms)
        #expect(vocabulary.contains("deploy") == false)
    }

    @Test
    func composedSpeechVocabularyExcludesBuiltInsWhenDisabled() {
        let glossary = GlossaryList(terms: [
            GlossaryTerm(term: "Syrup"),
            GlossaryTerm(term: "Zorvex"),
        ])

        let vocabulary = AppSettings.composedSpeechVocabulary(
            glossary: glossary,
            includeCommonTechTerms: false
        )

        #expect(vocabulary == ["Syrup", "Zorvex"])
    }

    @Test
    func composedSpeechVocabularyDeduplicatesCaseInsensitively() {
        let glossary = GlossaryList(terms: [GlossaryTerm(term: "Deploy")])

        let vocabulary = AppSettings.composedSpeechVocabulary(
            glossary: glossary,
            includeCommonTechTerms: true
        )

        #expect(vocabulary.first == "Deploy")
        #expect(vocabulary.filter { $0.lowercased() == "deploy" }.count == 1)
    }

    @Test
    func composedSpeechVocabularyNeverExceedsTheDefaultLimit() {
        let glossary = GlossaryList(terms: [GlossaryTerm(term: "Syrup")])

        let vocabulary = AppSettings.composedSpeechVocabulary(
            glossary: glossary,
            includeCommonTechTerms: true
        )

        #expect(vocabulary.count <= PromptBuilder.maximumGlossaryTerms)
    }

    @Test
    func codableRoundTripPreservesGlossary() throws {
        let termID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let glossary = GlossaryList(terms: [
            GlossaryTerm(
                id: termID,
                term: "Syrup",
                mishearings: ["sirup", "cyrup"]
            ),
        ])

        let data = try JSONEncoder().encode(glossary)
        let decoded = try JSONDecoder().decode(GlossaryList.self, from: data)

        #expect(decoded == glossary)
    }

    @Test
    func unknownVersionRunsEmptyWithoutReplacingStoredBlob() throws {
        let suiteName = "SyrupTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let futureBlob = Data(#"{"version":2,"terms":[{"id":"00000000-0000-0000-0000-000000000001","term":"Syrup","mishearings":[]}] }"#.utf8)
        userDefaults.set(futureBlob, forKey: "glossaryV1")

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(settings.glossaryList.terms.isEmpty)
        #expect(userDefaults.data(forKey: "glossaryV1") == futureBlob)

        settings.addGlossaryTerm(GlossaryTerm(term: "Added in an older build"))
        #expect(userDefaults.data(forKey: "glossaryV1") == futureBlob)
    }

    @Test
    func unknownProposalVersionSurvivesNewProposals() throws {
        let suiteName = "SyrupTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let futureBlob = Data(#"{"version":99,"proposals":[],"dismissedKeys":[]}"#.utf8)
        userDefaults.set(futureBlob, forKey: "glossaryProposalsV1")
        let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })

        settings.addGlossaryProposal(GlossaryProposal(
            id: UUID(), term: "Syrup", mishearings: ["sirup"], confidence: 0.9, createdAt: .now
        ))

        #expect(userDefaults.data(forKey: "glossaryProposalsV1") == futureBlob)
    }

    @Test
    func modelTrimsRejectsEmptyTermsAndKeepsFirstCaseInsensitiveDuplicate() {
        let firstID = UUID()
        let glossary = GlossaryList(terms: [
            GlossaryTerm(
                id: firstID,
                term: "  Syrup  ",
                mishearings: [" sirup ", "  ", "cyrup"]
            ),
            GlossaryTerm(term: "\n\t", mishearings: []),
            GlossaryTerm(term: "sYrUp", mishearings: ["duplicate"]),
            GlossaryTerm(term: " Zorvex ", mishearings: []),
        ])

        #expect(glossary.terms.map(\.id).first == firstID)
        #expect(glossary.terms.map(\.term) == ["Syrup", "Zorvex"])
        #expect(glossary.terms.first?.mishearings == ["sirup", "cyrup"])
    }

    @Test
    func corruptBlobRecoversWithEmptyGlossary() throws {
        let suiteName = "SyrupTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let corruptBlob = Data([0xFF])
        userDefaults.set(corruptBlob, forKey: "glossaryV1")

        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        #expect(settings.glossaryList.terms.isEmpty)
    }

    @Test
    func appSettingsPersistsAndReloadsNormalizedGlossaryBlob() throws {
        let suiteName = "SyrupTests.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            userDefaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )

        settings.addGlossaryTerm(GlossaryTerm(
            term: "  Syrup  ",
            mishearings: [" sirup ", "  "]
        ))
        settings.addGlossaryTerm(GlossaryTerm(term: "sYrUp"))

        let reloaded = AppSettings(
            userDefaults: userDefaults,
            defaultMicrophoneIDProvider: { "" }
        )
        let storedData = try #require(userDefaults.data(forKey: "glossaryV1"))
        let storedGlossary = try JSONDecoder().decode(GlossaryList.self, from: storedData)

        #expect(reloaded.glossaryList.terms.map(\.term) == ["Syrup"])
        #expect(reloaded.glossaryList.terms.first?.mishearings == ["sirup"])
        #expect(storedGlossary == reloaded.glossaryList)
    }

    @Test
    func persistedDuplicateRemainsRejectedWhileExistingEditorDraftIsCleared() {
        let existingTerm = GlossaryTerm(term: "Syrup")
        var glossary = GlossaryList(terms: [existingTerm])
        let clearedEditorDraft = ""

        #expect(glossary.validation(for: clearedEditorDraft, excluding: existingTerm.id) == .empty)
        #expect(glossary.validation(for: "sYrUp") == .duplicate)

        let originalGlossary = glossary
        let inserted = glossary.append(GlossaryTerm(term: "Syrup"))

        #expect(inserted == false)
        #expect(glossary == originalGlossary)
    }
}
