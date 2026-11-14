import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// History deletion and notification actions.
@MainActor
struct HistorySafeguardTests {
    @Test func historyDeletionFailurePreservesOptInAndRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupHistoryFailure"))
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let settings = fixtureSettings()
        let history = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        await settings.privacyOptIns(history: history).setPersistHistory(true)
        history.append(record("retained"))
        await history.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        #expect(await history.clear() == false)
        #expect(history.records.count == 1)
        await history.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        let state = appState(settings: settings, history: history)
        await state.privacyOptIns.setPersistHistory(false)
        #expect(settings.persistHistory)
        #expect(history.persistenceError != nil)
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path))
        await history.flush()
    }

    @Test func historyDeletionWaitsForQueuedWrites() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: testDomainName("SyrupHistoryBarrier"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        for index in 0..<40 { store.append(record("\(index)")) }
        await store.flush()
        let reloaded = HistoryStore(persistenceEnabled: true, storageDirectory: directory)
        #expect(reloaded.records.map(\.transcript) == (20..<40).reversed().map(String.init))
        store.append(record("last queued write"))
        #expect(await store.setPersistenceEnabled(false))
        store.append(record("memory only"))
        await store.flush()
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "history.json").path) == false)
    }

    @Test func notificationFallbackUsesOriginatingRecordAndIgnoresMissingID() {
        let history = HistoryStore()
        let original = record("original failure", failed: true)
        history.append(original)
        history.append(record("newer failure", failed: true))
        let pasteboard = SpyPasteboard()
        let state = appState(history: history, pasteboard: pasteboard)
        state.copyTranscriptFallback(recordID: original.id)
        state.copyTranscriptFallback(recordID: UUID())
        #expect(pasteboard.writes == ["original failure"])
    }

    private func fixtureSettings() -> AppSettings {
        let defaults = TestDefaults(suiteName: testDomainName("SyrupReviewTests"))!
        let settings = AppSettings(userDefaults: defaults, defaultMicrophoneIDProvider: { "" })
        settings.showRecordingCue = false
        settings.playSounds = false
        return settings
    }

    private func record(_ transcript: String, failed: Bool = false) -> DictationRecord {
        DictationRecord(id: UUID(), finishedAt: .now, transcript: transcript,
            output: failed ? nil : "output", transformation: .translation(targetLanguage: "English", toneInstruction: ""),
            outcome: failed ? .failed(message: "fixture") : .success)
    }

    private func appState(settings: AppSettings? = nil, history: HistoryStore = HistoryStore(),
                          pasteboard: SpyPasteboard = SpyPasteboard()) -> AppState {
        AppState.fixture(settings: settings ?? fixtureSettings(), history: history, audioRecorder: FakeRecorder(),
            transcriber: FakeTranscriber(.success("fixture")), transformer: FakeTextTransformer(.success("fixture")),
            pasteboard: pasteboard, feedback: SpyFeedback(), autoPaster: SpyAutoPaster(), maximumRecordingDurationNanoseconds: 0, recordingClock: FastForwardClock())
    }
}
