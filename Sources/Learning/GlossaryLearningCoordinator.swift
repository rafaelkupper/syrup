import AppKit
import Foundation
import Observation

struct TranscriptPair: Equatable, Sendable {
    let recordingID: UUID
    let localeID: String
    let appleTranscript: String
    let whisperTranscript: String
}

@MainActor
protocol CrossCheckSink: AnyObject, Sendable {
    /// Returns true when the pair was fully handled and its recording may be deleted.
    func process(_ pair: TranscriptPair) async -> Bool
}

@MainActor
final class JudgingCrossCheckSink: CrossCheckSink {
    private let settings: AppSettings
    private let judge: any MishearingJudging

    init(settings: AppSettings, judge: any MishearingJudging) {
        self.settings = settings
        self.judge = judge
    }

    /// The judge sees only the transcript pair. Findings that repeat an existing glossary term,
    /// a pending proposal, or a dismissed one are dropped here by `addGlossaryProposal`.
    func process(_ pair: TranscriptPair) async -> Bool {
        guard let findings = await judge.findings(for: pair) else {
            return false
        }

        guard settings.glossaryLearningEnabled, Task.isCancelled == false else { return false }
        settings.addGlossaryProposals(findings.map { finding in
            GlossaryProposal(
                id: UUID(),
                term: finding.term,
                mishearings: finding.mishearings,
                confidence: finding.confidence,
                createdAt: .now
            )
        })
        return true
    }
}

@MainActor
@Observable
final class GlossaryLearningCoordinator {
    typealias Schedule = (@escaping @MainActor @Sendable () async -> Void) -> Void

    static let maximumEntriesPerPass = 5
    static let maximumTranscriptCharacters = 4_000

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let archive: any RecordingArchiving
    @ObservationIgnored private let modelManager: any WhisperModelManaging
    @ObservationIgnored private let transcriber: any BatchTranscribing
    @ObservationIgnored private let sink: any CrossCheckSink
    @ObservationIgnored private var backgroundScheduler: NSBackgroundActivityScheduler?
    /// True while a pass is processing recordings; Settings uses it to show
    /// progress and to keep Remove Model / Clear disabled mid-pass.
    private(set) var isRunning = false
    @ObservationIgnored private var foregroundActive = false
    @ObservationIgnored private var passTask: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date

    init(
        settings: AppSettings,
        archive: any RecordingArchiving,
        modelManager: any WhisperModelManaging,
        transcriber: any BatchTranscribing,
        sink: any CrossCheckSink,
        schedule: Schedule? = nil,
        now: @escaping () -> Date = { .now }
    ) {
        self.settings = settings
        self.now = now
        self.archive = archive
        self.modelManager = modelManager
        self.transcriber = transcriber
        self.sink = sink

        let operation: @MainActor @Sendable () async -> Void = { [weak self] in
            await self?.runPass()
        }
        if let schedule {
            schedule(operation)
        } else {
            installDefaultSchedule(operation: operation)
        }
    }

    func setForegroundActive(_ active: Bool) {
        foregroundActive = active
        if active { passTask?.cancel() }
    }

    func runPass() async {
        guard settings.glossaryLearningEnabled, foregroundActive == false, isRunning == false else { return }
        isRunning = true
        let task = Task { await processPass() }
        passTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        passTask = nil
        isRunning = false
    }

    private func processPass() async {
        let pendingEntries = await archive.pendingEntries().filter { ($0.nextAttemptAt ?? .distantPast) <= now() }
        guard pendingEntries.isEmpty == false, Task.isCancelled == false, settings.glossaryLearningEnabled else { return }
        await modelManager.ensureModel()
        guard settings.glossaryLearningEnabled, Task.isCancelled == false, modelManager.state == .ready else { return }

        for entry in pendingEntries.prefix(Self.maximumEntriesPerPass) {
            guard settings.glossaryLearningEnabled, Task.isCancelled == false else { break }
            let fileURL = await archive.audioFileURL(id: entry.id)

            do {
                let whisperTranscript = try await transcriber.transcribe(
                    fileURL: fileURL,
                    languageCode: Self.languageCode(for: entry.localeID)
                )
                guard settings.glossaryLearningEnabled, Task.isCancelled == false else { break }
                let pair = TranscriptPair(
                    recordingID: entry.id,
                    localeID: entry.localeID,
                    appleTranscript: Self.trimmed(entry.appleTranscript),
                    whisperTranscript: Self.trimmed(whisperTranscript)
                )
                let handled = await sink.process(pair)
                guard settings.glossaryLearningEnabled, Task.isCancelled == false else { break }
                if handled {
                    await archive.deleteEntry(id: entry.id)
                } else {
                    await recordFailure(id: entry.id)
                }
            } catch is CancellationError {
                break
            } catch BatchTranscriptionError.modelUnavailable {
                // The model, not the recording, failed: no attempt is used up, and passes stop until
                // the person retries or removes the model. A pass being cancelled is not that.
                if Task.isCancelled == false { modelManager.modelFailedToLoad() }
                break
            } catch {
                guard Task.isCancelled == false else { break }
                await recordFailure(id: entry.id)
            }
        }

        await transcriber.releaseModels()
    }

    private func recordFailure(id: UUID) async {
        if await archive.recordAttempt(id: id) >= 3 {
            await archive.deleteEntry(id: id)
        }
    }

    static func languageCode(for localeID: String) -> String {
        String(localeID.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "en")
            .lowercased()
    }

    private static func trimmed(_ transcript: String) -> String {
        String(transcript.prefix(maximumTranscriptCharacters))
    }

    private func installDefaultSchedule(
        operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let scheduler = NSBackgroundActivityScheduler(
            identifier: "org.syrup.SyrupApp.glossary-learning"
        )
        scheduler.repeats = true
        scheduler.interval = 1_800
        scheduler.tolerance = 900
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            Task { @MainActor in
                await operation()
                completion(.finished)
            }
        }
        backgroundScheduler = scheduler
    }
}
