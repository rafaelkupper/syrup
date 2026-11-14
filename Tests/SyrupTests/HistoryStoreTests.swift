import Foundation
import Testing
@testable import Syrup

@MainActor
struct HistoryStoreTests {
    @Test
    func appendOrdersNewestFirstAndTrimsCapacity() throws {
        let store = HistoryStore(capacity: 2)
        let first = record(transcript: "one")
        let second = record(transcript: "two")
        let third = record(transcript: "three")

        store.append(first)
        store.append(second)
        store.append(third)

        #expect(store.records.map(\.transcript) == ["three", "two"])
    }

    @Test
    func clearRemovesMemoryAndPersistedFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(persistenceEnabled: true, storageDirectory: directory)

        store.append(record(transcript: "persisted"))
        await store.clear()

        #expect(store.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path(percentEncoded: false)) == false)
    }

    @Test
    func persistenceRoundTripsOnlyWhenEnabled() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let enabled = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        enabled.append(record(transcript: "saved"))

        await enabled.flush()
        let reloaded = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        #expect(reloaded.records.map(\.transcript) == ["saved"])

        let disabled = HistoryStore(persistenceEnabled: false, storageDirectory: directory)
        #expect(disabled.records.isEmpty)
    }

    @Test
    func turningPersistenceOnKeepsOnlyResultsMadeAfterwards() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        store.append(record(transcript: "kept, then opted out"))
        #expect(await store.setPersistenceEnabled(false))
        store.append(record(transcript: "made while off"))

        #expect(await store.setPersistenceEnabled(true))
        await store.flush()
        #expect(HistoryStore(persistenceEnabled: true, storageDirectory: directory).records.isEmpty)

        store.append(record(transcript: "made after turning it on"))
        await store.flush()
        #expect(store.records.map(\.transcript) == ["made after turning it on", "made while off", "kept, then opted out"])
        let reloaded = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        #expect(reloaded.records.map(\.transcript) == ["made after turning it on"])
    }

    @Test
    func disablingPersistenceDeletesFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        store.append(record(transcript: "saved"))

        await store.setPersistenceEnabled(false)

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path(percentEncoded: false)) == false)
    }

    @Test
    func corruptFileLoadsAsEmpty() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "history.json"))

        let store = HistoryStore(persistenceEnabled: true, storageDirectory: directory)

        #expect(store.records.isEmpty)
    }

    @Test
    func recordCodableRoundTripPreservesSnapshot() throws {
        let original = record(transcript: "bom dia")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DictationRecord.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func providerMetadataRoundTripsAndLegacyFailureRemainsReadable() throws {
        let original = DictationRecord(
            id: UUID(), finishedAt: .now, transcript: "fixture", output: nil,
            transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: .failed(message: "fixture failure"), provider: .appleOnDevice
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(DictationRecord.self, from: data) == original)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "provider")
        let decoded = try JSONDecoder().decode(
            DictationRecord.self, from: JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.provider == nil)
        #expect(decoded.canRetry)
        #expect(decoded.canRetryWithOriginalProvider == false)
        #expect(decoded.transformation == original.transformation)
    }

    @Test
    func revisionSnapshotCodableRoundTripPreservesAdjustmentAndInstruction() throws {
        let original = DictationRecord.TransformationSnapshot.revision(
            adjustment: "mais curto\ne mais simpatico",
            instruction: PromptBuilder.compose(
                base: PromptBuilder.revisionInstruction(adjustment: "mais curto\ne mais simpatico"),
                glossary: nil,
                context: nil,
                contract: PromptBuilder.outputContract
            )
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            DictationRecord.TransformationSnapshot.self,
            from: data
        )

        #expect(decoded == original)
    }

    @Test
    func preWaveZeroRecordBlobStillDecodesAfterSnapshotCasesAreAdded() throws {
        let blob = Data(
            #"{"id":"00000000-0000-0000-0000-000000000001","finishedAt":0,"transcript":"bom dia","output":"good morning","transformation":{"translation":{"targetLanguage":"English","toneInstruction":""}},"outcome":{"success":{}}}"#.utf8
        )

        let decoded = try JSONDecoder().decode(DictationRecord.self, from: blob)

        #expect(decoded.id == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        #expect(decoded.transformation == .translation(targetLanguage: "English", toneInstruction: ""))
        #expect(decoded.outcome == .success)
    }

    @Test
    func snapshotCasesGuardFallbackAndRetryBehavior() {
        let revision = failedRecord(transformation: .revision(
            adjustment: "shorter",
            instruction: "Revise the text."
        ))
        let contextual = failedRecord(transformation: .contextual(
            workflowName: "Reply Draft",
            instruction: "Draft a reply."
        ))
        let translation = failedRecord(transformation: .translation(
            targetLanguage: "English",
            toneInstruction: ""
        ))

        #expect(revision.canUseTranscriptFallback == false)
        #expect(revision.canRetry)
        #expect(contextual.canUseTranscriptFallback == false)
        #expect(contextual.canRetry == false)
        #expect(translation.canUseTranscriptFallback)
        #expect(translation.canRetry)
    }

    private func record(transcript: String) -> DictationRecord {
        DictationRecord(
            id: UUID(),
            finishedAt: Date(timeIntervalSince1970: 1_234),
            transcript: transcript,
            output: "output \(transcript)",
            transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: .success
        )
    }

    private func failedRecord(
        transformation: DictationRecord.TransformationSnapshot
    ) -> DictationRecord {
        DictationRecord(
            id: UUID(),
            finishedAt: Date(timeIntervalSince1970: 1_234),
            transcript: "input",
            output: nil,
            transformation: transformation,
            outcome: .failed(message: "failed")
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: testDomainName("SyrupHistoryTests"), directoryHint: .isDirectory)
    }
}
