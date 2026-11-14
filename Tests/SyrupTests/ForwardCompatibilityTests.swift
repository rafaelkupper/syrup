import Foundation
import Testing
@testable import Syrup

/// Data written by a newer build, read by this one. A provider this build doesn't know must not cost
/// the workflow list or history.
@MainActor
struct ForwardCompatibilityTests {
    private func record(provider: TranslationProvider?, transcript: String) -> DictationRecord {
        DictationRecord(
            id: UUID(), finishedAt: Date(timeIntervalSince1970: 1_700_000_000), transcript: transcript,
            output: "out", transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: .success, provider: provider
        )
    }

    /// Encodes with Claude Code, then renames it to a provider no build knows yet.
    private func futureJSON<T: Encodable>(_ value: T) throws -> Data {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        #expect(json.contains("claude_cli"))
        return Data(json.replacingOccurrences(of: "claude_cli", with: "some_future_provider").utf8)
    }

    @Test func aWorkflowWithAnUnknownProviderLoadsWithTheDefaultProvider() throws {
        let workflow = Workflow(
            id: UUID(), name: "Polish", kind: .custom(instruction: "Polish it.", enforceOutputContract: true),
            dictationLocaleID: "en-US", translationProvider: .claudeCLI
        )
        let decoded = try JSONDecoder().decode(Workflow.self, from: futureJSON(workflow))
        #expect(decoded.id == workflow.id)
        #expect(decoded.name == workflow.name)
        #expect(decoded.translationProvider == nil)
    }

    @Test func aHistoryRecordWithAnUnknownProviderStillLoads() throws {
        let original = record(provider: .claudeCLI, transcript: "bom dia")
        let decoded = try JSONDecoder().decode(DictationRecord.self, from: futureJSON(original))
        #expect(decoded.transcript == "bom dia")
        #expect(decoded.provider == nil)
        #expect(try JSONDecoder().decode(DictationRecord.self, from: JSONEncoder().encode(original)) == original)
    }

    @Test func oneUnreadableHistoryRecordDoesNotCostTheOthers() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "SyrupForwardHistory.\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = record(provider: .openAICompatible, transcript: "kept")
        let keptJSON = String(decoding: try JSONEncoder().encode(kept), as: UTF8.self)
        let file = "[" + keptJSON + #",{"id":"not-a-uuid","outcome":{"somethingNew":{}}}]"#
        try Data(file.utf8).write(to: directory.appending(path: "history.json"))

        let history = HistoryStore(persistenceEnabled: true, storageDirectory: directory)

        #expect(history.records == [kept])
    }

    @Test func aWorkflowListWithNoWorkflowsFailsToDecodeInsteadOfTrappingLater() {
        let json = #"{"version":3,"workflows":[],"activeWorkflowID":"\#(UUID().uuidString)"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(WorkflowList.self, from: Data(json.utf8))
        }
    }
}
