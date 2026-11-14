import Foundation
import Testing
@testable import Syrup

@MainActor
struct GlossaryLearningCoordinatorTests {
    @Test
    func disabledSettingBailsOutBeforeModelOrTranscription() async {
        let settings = makeCoordinatorSettings(enabled: false)
        let modelManager = FakeWhisperModelManager(state: .ready)
        let archive = CoordinatorArchive(entries: [sidecar(index: 0)])
        let transcriber = CoordinatorBatchTranscriber()
        let coordinator = makeCoordinator(
            settings: settings,
            archive: archive,
            modelManager: modelManager,
            transcriber: transcriber
        )

        await coordinator.runPass()

        #expect(modelManager.ensureCount == 0)
        #expect(await transcriber.calls.isEmpty)
        #expect(await transcriber.releaseCount == 0)
    }

    @Test
    func passProcessesOnlyFiveOldestEntriesSequentially() async {
        let settings = makeCoordinatorSettings(enabled: true)
        let entries = (0..<7).map { sidecar(index: $0) }
        let archive = CoordinatorArchive(entries: entries)
        let transcriber = CoordinatorBatchTranscriber()
        let sink = CoordinatorSink(result: true)
        let coordinator = makeCoordinator(
            settings: settings,
            archive: archive,
            transcriber: transcriber,
            sink: sink
        )

        await coordinator.runPass()

        #expect(await transcriber.calls.map(\.fileURL.lastPathComponent) == entries.prefix(5).map { "\($0.id.uuidString).wav" })
        #expect(sink.pairs.map(\.recordingID) == entries.prefix(5).map(\.id))
        #expect(await archive.deletedEntryIDs == entries.prefix(5).map(\.id))
        #expect(await transcriber.releaseCount == 1)
    }

    @Test
    func sinkSuccessDeletesRecordingAndUsesLanguageSubtag() async {
        let settings = makeCoordinatorSettings(enabled: true)
        let entry = sidecar(index: 0, localeID: "pt-BR")
        let archive = CoordinatorArchive(entries: [entry])
        let transcriber = CoordinatorBatchTranscriber(transcript: "Whisper deploy")
        let sink = CoordinatorSink(result: true)
        let coordinator = makeCoordinator(
            settings: settings,
            archive: archive,
            transcriber: transcriber,
            sink: sink
        )

        await coordinator.runPass()

        #expect(await transcriber.calls.map(\.languageCode) == ["pt"])
        #expect(await archive.deletedEntryIDs == [entry.id])
        #expect(sink.pairs == [TranscriptPair(
            recordingID: entry.id,
            localeID: "pt-BR",
            appleTranscript: entry.appleTranscript,
            whisperTranscript: "Whisper deploy"
        )])
    }

    @Test
    func sinkFailureCountsTowardBoundedRetries() async {
        let settings = makeCoordinatorSettings(enabled: true)
        let entry = sidecar(index: 0)
        let archive = CoordinatorArchive(entries: [entry])
        let coordinator = makeCoordinator(
            settings: settings,
            archive: archive,
            sink: CoordinatorSink(result: false)
        )

        await coordinator.runPass()

        #expect(await archive.deletedEntryIDs.isEmpty)
        #expect(await archive.attempts(for: entry.id) == 1)
    }

    @Test
    func unavailableJudgeRetainsRecordingThroughRealSink() async {
        let settings = makeCoordinatorSettings(enabled: true)
        settings.addGlossaryTerm(GlossaryTerm(term: "Existing"))
        let entry = sidecar(index: 0)
        let archive = CoordinatorArchive(entries: [entry])
        let judge = CoordinatorJudge(findings: nil)
        let sink = JudgingCrossCheckSink(settings: settings, judge: judge)
        let coordinator = makeCoordinator(
            settings: settings,
            archive: archive,
            sink: sink
        )

        await coordinator.runPass()

        #expect(await archive.deletedEntryIDs.isEmpty)
        #expect(await archive.attempts(for: entry.id) == 1)
        #expect(settings.glossaryProposals.proposals.isEmpty)
        #expect(await judge.pairs.count == 1)
    }

    @Test
    func existingGlossaryTermsAreFilteredLocallyNotSentToTheJudge() async {
        let settings = makeCoordinatorSettings(enabled: true)
        settings.addGlossaryTerm(GlossaryTerm(term: "Existing"))
        let judge = CoordinatorJudge(findings: [
            JudgeFinding(term: "existing", mishearings: ["exist ting"], confidence: 0.9),
            JudgeFinding(term: "Syrup", mishearings: ["sirup"], confidence: 0.8),
        ])
        let sink = JudgingCrossCheckSink(settings: settings, judge: judge)
        let pair = TranscriptPair(
            recordingID: UUID(), localeID: "pt-BR",
            appleTranscript: "hello", whisperTranscript: "hello"
        )

        #expect(await sink.process(pair))
        #expect(await judge.pairs == [pair])
        #expect(settings.glossaryProposals.proposals.map(\.term) == ["Syrup"])
    }

    @Test
    func repeatedFindingCreatesOnlyOneProposal() async {
        let settings = makeCoordinatorSettings(enabled: true)
        let judge = CoordinatorJudge(findings: [JudgeFinding(
            term: "Syrup",
            mishearings: ["sirup"],
            confidence: 0.8
        )])
        let sink = JudgingCrossCheckSink(settings: settings, judge: judge)
        let pair = TranscriptPair(
            recordingID: UUID(),
            localeID: "pt-BR",
            appleTranscript: "sirup",
            whisperTranscript: "Syrup"
        )

        let firstResult = await sink.process(pair)
        let secondResult = await sink.process(pair)

        #expect(firstResult)
        #expect(secondResult)
        #expect(settings.glossaryProposals.proposals.count == 1)
        #expect(settings.glossaryProposals.proposals.first?.term == "Syrup")
        #expect(settings.glossaryProposals.proposals.first?.mishearings == ["sirup"])
    }

    @Test
    func thirdTranscriptionFailureDeletesRecording() async {
        let settings = makeCoordinatorSettings(enabled: true)
        let entry = sidecar(index: 0)
        let archive = CoordinatorArchive(entries: [entry])
        let transcriber = CoordinatorBatchTranscriber(error: CoordinatorTestError.transcription)
        let coordinator = makeCoordinator(
            settings: settings,
            archive: archive,
            transcriber: transcriber
        )

        await coordinator.runPass()
        await coordinator.runPass()
        #expect(await archive.deletedEntryIDs.isEmpty)
        #expect(await archive.attempts(for: entry.id) == 2)

        await coordinator.runPass()

        #expect(await archive.deletedEntryIDs == [entry.id])
        #expect(await transcriber.calls.count == 3)
        #expect(await transcriber.releaseCount == 3)
    }

    @Test
    func transcriptPairIsBoundedToFourThousandCharacters() async throws {
        let settings = makeCoordinatorSettings(enabled: true)
        let longText = String(repeating: "a", count: 4_010)
        let entry = RecordingSidecar(
            id: UUID(),
            createdAt: .now,
            localeID: "en_US",
            appleTranscript: longText,
            attempts: 0
        )
        let archive = CoordinatorArchive(entries: [entry])
        let sink = CoordinatorSink(result: false)
        let coordinator = makeCoordinator(
            settings: settings,
            archive: archive,
            transcriber: CoordinatorBatchTranscriber(transcript: longText),
            sink: sink
        )

        await coordinator.runPass()

        let pair = try #require(sink.pairs.first)
        #expect(pair.appleTranscript.count == 4_000)
        #expect(pair.whisperTranscript.count == 4_000)
    }

    private func makeCoordinator(
        settings: AppSettings,
        archive: CoordinatorArchive,
        modelManager: FakeWhisperModelManager = FakeWhisperModelManager(state: .ready),
        transcriber: CoordinatorBatchTranscriber = CoordinatorBatchTranscriber(),
        sink: any CrossCheckSink = CoordinatorSink(result: true)
    ) -> GlossaryLearningCoordinator {
        GlossaryLearningCoordinator(
            settings: settings,
            archive: archive,
            modelManager: modelManager,
            transcriber: transcriber,
            sink: sink,
            schedule: { _ in }
        )
    }

    private func makeCoordinatorSettings(enabled: Bool) -> AppSettings {
        let suiteName = testDomainName("SyrupGlossaryLearningCoordinatorTests")
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.glossaryLearningEnabled = enabled
        return settings
    }

    private func sidecar(index: Int, localeID: String = "pt-BR") -> RecordingSidecar {
        RecordingSidecar(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
            localeID: localeID,
            appleTranscript: "Apple \(index)",
            attempts: 0
        )
    }
}

@MainActor
struct WhisperModelManagerTests {
    @Test
    func incompleteDownloadIsNotReportedReady() throws {
        let directory = temporaryModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let incompleteModelDirectory = modelDirectory(in: directory)
        try FileManager.default.createDirectory(
            at: incompleteModelDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: incompleteModelDirectory.appending(path: "tokenizer.json"))

        let manager = WhisperModelManager(storageDirectory: directory)

        #expect(manager.state == .notDownloaded)
    }

    @Test
    func completeLocalModelIsReportedReadyWithoutNetwork() throws {
        let directory = temporaryModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let completeModelDirectory = modelDirectory(in: directory)
        try FileManager.default.createDirectory(
            at: completeModelDirectory,
            withIntermediateDirectories: true
        )
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(
                at: completeModelDirectory.appending(path: "\(component).mlmodelc"),
                withIntermediateDirectories: true
            )
        }
        try Data().write(to: completeModelDirectory.appending(path: "tokenizer.json"))

        let manager = WhisperModelManager(storageDirectory: directory)

        #expect(manager.state == .ready)
        #expect(
            manager.modelDirectory.standardizedFileURL.path(percentEncoded: false)
                == completeModelDirectory.standardizedFileURL.path(percentEncoded: false)
        )
    }

    private func temporaryModelDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: testDomainName("SyrupWhisperModelManagerTests"))
    }

    private func modelDirectory(in storageDirectory: URL) -> URL {
        storageDirectory
            .appending(path: "models")
            .appending(path: "argmaxinc")
            .appending(path: "whisperkit-coreml")
            .appending(path: WhisperModelManager.modelVariant)
    }
}

private enum CoordinatorTestError: Error {
    case transcription
}

private actor CoordinatorJudge: MishearingJudging {
    private let result: [JudgeFinding]?
    private(set) var pairs: [TranscriptPair] = []

    init(findings: [JudgeFinding]?) {
        self.result = findings
    }

    func findings(for pair: TranscriptPair) async -> [JudgeFinding]? {
        pairs.append(pair)
        return result
    }
}

@MainActor
private final class FakeWhisperModelManager: WhisperModelManaging {
    var state: WhisperModelManager.State
    private(set) var ensureCount = 0

    init(state: WhisperModelManager.State) {
        self.state = state
    }

    func ensureModel() async {
        ensureCount += 1
    }
}

private actor CoordinatorBatchTranscriber: BatchTranscribing {
    struct Call: Sendable {
        let fileURL: URL
        let languageCode: String
    }

    private let transcript: String
    private let error: (any Error & Sendable)?
    private(set) var calls: [Call] = []
    private(set) var releaseCount = 0

    init(transcript: String = "Whisper", error: (any Error & Sendable)? = nil) {
        self.transcript = transcript
        self.error = error
    }

    func transcribe(fileURL: URL, languageCode: String) async throws -> String {
        calls.append(Call(fileURL: fileURL, languageCode: languageCode))
        if let error { throw error }
        return transcript
    }

    func releaseModels() async {
        releaseCount += 1
    }
}

@MainActor
private final class CoordinatorSink: CrossCheckSink {
    private let result: Bool
    private(set) var pairs: [TranscriptPair] = []

    init(result: Bool) {
        self.result = result
    }

    func process(_ pair: TranscriptPair) async -> Bool {
        pairs.append(pair)
        return result
    }
}

private actor CoordinatorArchive: RecordingArchiving {
    private var entries: [RecordingSidecar]
    private(set) var deletedEntryIDs: [UUID] = []

    init(entries: [RecordingSidecar]) {
        self.entries = entries.sorted { $0.createdAt < $1.createdAt }
    }

    func beginEntry(id: UUID) async throws -> URL {
        await audioFileURL(id: id)
    }

    func commitEntry(id: UUID, localeID: String, appleTranscript: String) async {}
    func discardEntry(id: UUID) async -> Bool { await deleteEntry(id: id) }
    func unresolvedDeletions() async -> Set<UUID> { [] }

    func pendingEntryCounts() async -> AsyncStream<Int> {
        let count = await pendingEntries().count
        return AsyncStream { $0.yield(count); $0.finish() }
    }

    func pendingEntries() async -> [RecordingSidecar] {
        entries
    }

    func audioFileURL(id: UUID) async -> URL {
        FileManager.default.temporaryDirectory.appending(path: "\(id.uuidString).wav")
    }

    func recordAttempt(id: UUID) async -> Int {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return 3 }
        let current = entries[index]
        let updated = RecordingSidecar(
            id: current.id,
            createdAt: current.createdAt,
            localeID: current.localeID,
            appleTranscript: current.appleTranscript,
            attempts: current.attempts + 1
        )
        entries[index] = updated
        return updated.attempts
    }

    func deleteEntry(id: UUID) async -> Bool {
        deletedEntryIDs.append(id)
        entries.removeAll { $0.id == id }
        return true
    }

    func deleteAll() async throws {
        entries.removeAll()
    }

    func attempts(for id: UUID) -> Int? {
        entries.first(where: { $0.id == id })?.attempts
    }
}

extension GlossaryLearningCoordinatorTests {
    @Test func emptyQueueDoesNotDownloadRemovedModel() async {
        let model = FakeWhisperModelManager(state: .notDownloaded)
        let coordinator = makeCoordinator(settings: makeCoordinatorSettings(enabled: true),
            archive: CoordinatorArchive(entries: []), modelManager: model)
        await coordinator.runPass()
        #expect(model.ensureCount == 0)
    }

    @Test func foregroundRunCancelsLearningAndReleasesModelsWithoutChargingRetry() async {
        let entry = sidecar(index: 0)
        let archive = CoordinatorArchive(entries: [entry])
        let transcriber = CancellableBatchTranscriber()
        let model = FakeWhisperModelManager(state: .ready)
        let coordinator = GlossaryLearningCoordinator(settings: makeCoordinatorSettings(enabled: true),
            archive: archive, modelManager: model, transcriber: transcriber,
            sink: CoordinatorSink(result: true), schedule: { _ in })
        coordinator.setForegroundActive(true)
        await coordinator.runPass()
        #expect(model.ensureCount == 0)
        coordinator.setForegroundActive(false)
        let pass = Task { await coordinator.runPass() }
        await eventually { await transcriber.started }
        #expect(await transcriber.started)
        coordinator.setForegroundActive(true)
        await pass.value
        #expect(await transcriber.released)
        #expect(await archive.attempts(for: entry.id) == 0)
        #expect(await archive.deletedEntryIDs.isEmpty)
    }

    @Test func judgeFailuresBackOffAndAllowNewerRecordingsToProgress() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupBackoff"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let archive = RecordingArchive(storageDirectory: directory, now: { timestamp })
        for _ in 0..<7 {
            let id = UUID()
            _ = try await archive.beginEntry(id: id)
            await archive.commitEntry(id: id, localeID: "en-US", appleTranscript: "fixture")
        }
        let sink = CoordinatorSink(result: false)
        let transcriber = CoordinatorBatchTranscriber()
        let coordinator = GlossaryLearningCoordinator(settings: makeCoordinatorSettings(enabled: true),
            archive: archive, modelManager: FakeWhisperModelManager(state: .ready), transcriber: transcriber,
            sink: sink, schedule: { _ in }, now: { timestamp })
        await coordinator.runPass()
        await coordinator.runPass()
        await coordinator.runPass()
        #expect(await transcriber.calls.count == 7)
        #expect(Set(sink.pairs.map(\.recordingID)).count == 7)
        let remaining = await archive.pendingEntries()
        #expect(remaining.allSatisfy { $0.attempts == 1 && $0.nextAttemptAt == timestamp.addingTimeInterval(1_800) })
    }

    @Test func threeJudgeFailuresRetireRecording() async {
        let entry = sidecar(index: 0)
        let archive = CoordinatorArchive(entries: [entry])
        let coordinator = makeCoordinator(settings: makeCoordinatorSettings(enabled: true), archive: archive,
            sink: CoordinatorSink(result: false))
        for _ in 0..<3 { await coordinator.runPass() }
        #expect(await archive.deletedEntryIDs == [entry.id])
    }
}

private actor CancellableBatchTranscriber: BatchTranscribing {
    private(set) var started = false
    private(set) var released = false
    func transcribe(fileURL: URL, languageCode: String) async throws -> String {
        started = true
        try await Task.sleep(for: .seconds(60))
        return "unexpected"
    }
    func releaseModels() async { released = true }
}
