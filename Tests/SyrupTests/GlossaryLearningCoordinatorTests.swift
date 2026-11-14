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

    /// A model that fails to load is the model's fault, not the recording's: no attempt is used up,
    /// the pass stops, and the model is marked failed.
    @Test
    func aModelThatFailsToLoadUsesUpNoRecordings() async throws {
        let archive = CoordinatorArchive(entries: [sidecar(index: 0), sidecar(index: 1)])
        let modelManager = FakeWhisperModelManager(state: .ready)
        let transcriber = CoordinatorBatchTranscriber(error: BatchTranscriptionError.modelUnavailable)
        let coordinator = makeCoordinator(
            settings: makeCoordinatorSettings(enabled: true), archive: archive,
            modelManager: modelManager, transcriber: transcriber
        )

        await coordinator.runPass()

        #expect(await transcriber.calls.count == 1)
        #expect(await archive.pendingEntries().map(\.attempts) == [0, 0])
        #expect(await archive.deletedEntryIDs.isEmpty)
        #expect(modelManager.state == .failed("The recognition model couldn't load."))
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
        let defaults = TestDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.privacyOptIns.setGlossaryLearning(enabled)
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

    /// Quitting mid-download used to leave the three model folders and the tokenizer, which counted
    /// as ready; every pass then failed to load it and used up the recordings.
    @Test
    func modelFoldersWithoutTheirCompiledDataAreNotReady() throws {
        let directory = temporaryModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = modelDirectory(in: directory)
        for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            try FileManager.default.createDirectory(at: partial.appending(path: "\(component).mlmodelc"), withIntermediateDirectories: true)
        }
        try Data().write(to: partial.appending(path: "tokenizer.json"))

        #expect(WhisperModelManager(storageDirectory: directory).state == .notDownloaded)
    }

    /// The model as Hugging Face publishes it, with the tokenizer Syrup fetches beside it, is ready.
    /// The earlier check wanted a `tokenizer.json` inside the model folder, which the published folder
    /// never has, so a real download could never become ready.
    @Test
    func thePublishedLayoutWithItsTokenizerIsReady() throws {
        let directory = temporaryModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try WhisperPublishedLayout.write(in: directory, tokenizer: true)
        #expect(WhisperModelManager(storageDirectory: directory).state == .ready)
    }

    @Test
    func thePublishedLayoutWithoutItsTokenizerIsNotReady() throws {
        let directory = temporaryModelDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try WhisperPublishedLayout.write(in: directory, tokenizer: false)
        #expect(WhisperModelManager(storageDirectory: directory).state == .notDownloaded)
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

    func modelFailedToLoad() {
        state = .failed("The recognition model couldn't load.")
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

/// The comparison model's files as Hugging Face publishes them (`argmaxinc/whisperkit-coreml`,
/// `openai_whisper-large-v3-v20240930_626MB`, listed 2026-11-14), and the tokenizer files WhisperKit
/// fetches from `openai/whisper-large-v3` into its hub layout. Tests build on this, not on what the
/// code expects, so a check the real download cannot pass fails here.
enum WhisperPublishedLayout {
    static let modelFiles = ["AudioEncoder", "MelSpectrogram", "TextDecoder"].flatMap { bundle in
        ["analytics/coremldata.bin", "coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"]
            .map { "\(bundle).mlmodelc/\($0)" }
    } + ["config.json", "generation_config.json"]
    static let tokenizerFiles = ["config.json", "tokenizer.json", "tokenizer_config.json"]

    static func modelFolder(in base: URL) -> URL {
        base.appending(path: "models/argmaxinc/whisperkit-coreml/\(WhisperModelManager.modelVariant)", directoryHint: .isDirectory)
    }

    static func tokenizerFolder(in base: URL) -> URL {
        base.appending(path: "models/openai/whisper-large-v3", directoryHint: .isDirectory)
    }

    static func write(in base: URL, tokenizer: Bool) throws {
        try writeModel(in: base)
        if tokenizer { try writeTokenizer(in: base) }
    }

    static func writeModel(in base: URL) throws {
        for file in modelFiles { try writeFile(modelFolder(in: base).appending(path: file)) }
    }

    static func writeTokenizer(in base: URL) throws {
        for file in tokenizerFiles { try writeFile(tokenizerFolder(in: base).appending(path: file)) }
    }

    private static func writeFile(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }
}
