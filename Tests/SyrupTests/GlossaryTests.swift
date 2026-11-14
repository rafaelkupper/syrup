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
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
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
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
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
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
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

    /// A blob this build cannot use is copied to a backup key before the first edit replaces it:
    /// data that does not decode, an older version, for the glossary, proposals, and workflows alike.
    @Test(arguments: [
        ("glossaryV1", Data([0xFF])),
        ("glossaryV1", Data(#"{"version":0,"terms":[{"id":"00000000-0000-0000-0000-000000000001","term":"Old","mishearings":[]}]}"#.utf8)),
        ("glossaryProposalsV1", Data(#"{"version":1,"proposals":"not a list"}"#.utf8)),
        ("workflowListV3", Data(#"{"version":3,"workflows":[{"kind":{"aNewerKind":{}}}],"activeWorkflowID":"x"}"#.utf8)),
    ])
    func unusableBlobsSurviveTheFirstEdit(key: String, blob: Data) throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        userDefaults.set(blob, forKey: key)
        let backupKey = AppSettings.unusableBlobBackupKey(for: blob, key: key)

        let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        #expect(userDefaults.data(forKey: backupKey) == blob)
        switch key {
        case "glossaryV1":
            #expect(settings.glossaryList.terms.isEmpty)
            settings.addGlossaryTerm(GlossaryTerm(term: "Syrup"))
        case "glossaryProposalsV1":
            #expect(settings.glossaryProposals.proposals.isEmpty)
            settings.addGlossaryProposal(GlossaryProposal(
                id: UUID(), term: "Syrup", mishearings: ["sirup"], confidence: 0.9, createdAt: .now
            ))
        default:
            settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.name = "Edited" }
        }

        #expect(userDefaults.data(forKey: key) != blob)
        #expect(userDefaults.data(forKey: backupKey) == blob)
        let backups = userDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("\(key).unreadable.") }
        _ = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        #expect(userDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("\(key).unreadable.") } == backups)
        #expect(backups.count == 1)
    }

    /// A backup holds user content, so a second unreadable blob replaces the first backup instead of
    /// adding another.
    @Test
    func onlyTheNewestBackupPerKeyIsKept() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let first = Data([0xFF]), second = Data([0xFE])
        userDefaults.set(Data([0x01]), forKey: "workflowListV3.unreadable.unrelated-key-prefix-check")
        userDefaults.set(first, forKey: "glossaryV1")
        _ = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        userDefaults.set(second, forKey: "glossaryV1")
        _ = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })

        let backups = userDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("glossaryV1.unreadable.") }
        #expect(backups == [AppSettings.unusableBlobBackupKey(for: second, key: "glossaryV1")])
        #expect(userDefaults.data(forKey: "workflowListV3.unreadable.unrelated-key-prefix-check") != nil)
    }

    /// Backups left by an earlier build, beside the current blob's own: finding its backup already
    /// there still removes the others.
    @Test
    func olderBackupsGoEvenWhenTheCurrentOneAlreadyExists() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let current = Data([0xFF]), older = Data([0xFE])
        userDefaults.set(current, forKey: "glossaryV1")
        userDefaults.set(current, forKey: AppSettings.unusableBlobBackupKey(for: current, key: "glossaryV1"))
        userDefaults.set(older, forKey: AppSettings.unusableBlobBackupKey(for: older, key: "glossaryV1"))

        _ = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })

        let backups = userDefaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("glossaryV1.unreadable.") }
        #expect(backups == [AppSettings.unusableBlobBackupKey(for: current, key: "glossaryV1")])
    }

    /// The backup holds terms the person may later delete. Emptying the glossary drops it; a glossary
    /// that still has terms keeps it.
    @Test
    func emptyingTheGlossaryDropsItsBackup() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let unreadable = Data([0xFF])
        userDefaults.set(unreadable, forKey: "glossaryV1")
        let backupKey = AppSettings.unusableBlobBackupKey(for: unreadable, key: "glossaryV1")
        let settings = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })
        let term = GlossaryTerm(term: "Syrup")
        settings.addGlossaryTerm(term)
        #expect(userDefaults.data(forKey: backupKey) == unreadable)

        settings.deleteGlossaryTerm(id: term.id)
        #expect(settings.glossaryList.terms.isEmpty)
        #expect(userDefaults.data(forKey: backupKey) == nil)
    }

    /// A newer build's blob is not copied: it stays where it is and is never overwritten.
    @Test
    func aNewerBlobGetsNoBackup() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let futureBlob = Data(#"{"version":2,"terms":"a newer shape"}"#.utf8)
        userDefaults.set(futureBlob, forKey: "glossaryV1")

        _ = AppSettings(userDefaults: userDefaults, defaultMicrophoneIDProvider: { "" })

        #expect(userDefaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("glossaryV1.unreadable.") } == false)
        #expect(userDefaults.data(forKey: "glossaryV1") == futureBlob)
    }

    @Test
    func appSettingsPersistsAndReloadsNormalizedGlossaryBlob() throws {
        let suiteName = testDomainName("SyrupTests")
        let userDefaults = try #require(TestDefaults(suiteName: suiteName))
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
