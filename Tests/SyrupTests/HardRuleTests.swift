import Foundation
import Testing
@testable import Syrup

/// The AGENTS.md hard rules that code can check, each named after its rule, so a change that breaks
/// a rule fails a test that says which. Other suites cover the same ground in more detail; these pin
/// the rule's own wording.
@MainActor
struct HardRuleTests {
    private func settings(_ defaults: UserDefaults) -> AppSettings {
        AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
    }

    /// Settings: "A blob written by a newer build loads empty (the workflow list falls back to the
    /// default workflow) and is never overwritten." Even with an older workflow list still stored.
    @Test func settingsANewerBuildsBlobsLoadEmptyOrAsTheDefaultWorkflowAndAreNeverOverwritten() throws {
        let suite = testDomainName("HardRules")
        let defaults = try #require(TestDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let newerWorkflows = Data(#"{"version":99,"workflows":"a newer shape"}"#.utf8)
        let newerGlossary = Data(#"{"version":99,"terms":"a newer shape"}"#.utf8)
        let newerProposals = Data(#"{"version":99,"proposals":"a newer shape"}"#.utf8)
        defaults.set(newerWorkflows, forKey: "workflowListV3")
        defaults.set(newerGlossary, forKey: "glossaryV1")
        defaults.set(newerProposals, forKey: "glossaryProposalsV1")
        defaults.set(Data(
            #"{"version":1,"workflows":[{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy Polish","kind":{"custom":{"instruction":"Polish this.","enforceOutputContract":true}},"dictationLocaleID":"pt-BR","translationProvider":null}],"activeWorkflowID":"00000000-0000-0000-0000-000000000001"}"#.utf8
        ), forKey: "workflowListV1")

        let settings = settings(defaults)
        #expect(settings.workflowList.workflows.map(\.name) == ["Translate"])
        #expect(settings.glossaryList.terms.isEmpty)
        #expect(settings.glossaryProposals.proposals.isEmpty)

        settings.updateWorkflow(id: settings.activeWorkflow.id) { $0.name = "Edited" }
        settings.addGlossaryTerm(GlossaryTerm(term: "Syrup"))
        settings.addGlossaryProposal(GlossaryProposal(id: UUID(), term: "Syrup", mishearings: ["sirup"], confidence: 0.9, createdAt: .now))
        #expect(defaults.data(forKey: "workflowListV3") == newerWorkflows)
        #expect(defaults.data(forKey: "glossaryV1") == newerGlossary)
        #expect(defaults.data(forKey: "glossaryProposalsV1") == newerProposals)
    }

    /// Settings: "A blob this build cannot read is copied once to `<key>.unreadable.<digest>` before an
    /// edit replaces it; ... only the newest backup per key is kept." The backup holds terms the person
    /// never saw, so emptying the new glossary keeps it.
    @Test func settingsAnUnreadableBlobKeepsItsNewestBackup() throws {
        let suite = testDomainName("HardRules")
        let defaults = try #require(TestDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let unreadable = Data([0xFF])
        defaults.set(unreadable, forKey: "glossaryV1")
        let backupKey = AppSettings.unusableBlobBackupKey(for: unreadable, key: "glossaryV1")

        let settings = settings(defaults)
        let term = GlossaryTerm(term: "Syrup")
        settings.addGlossaryTerm(term)
        settings.deleteGlossaryTerm(id: term.id)

        #expect(defaults.data(forKey: "glossaryV1") != unreadable)
        #expect(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("glossaryV1.unreadable.") } == [backupKey])
        #expect(defaults.data(forKey: backupKey) == unreadable)
    }
}
