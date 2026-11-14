import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// The opt-in recording archive for glossary learning.
@MainActor
struct AppStateLearningTests {
    @Test
    func learningEnabledArchivesSuccessfulVoiceRun() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            pasteboard: pasteboard,
            recordingArchive: archive
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        await eventually { await archive.snapshot().commits.count == 1 }
        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        let commit = try #require(snapshot.commits.first)
        #expect(snapshot.begunEntryIDs.count == 1)
        #expect(commit.id == begunID)
        #expect(commit.localeID == AppSettings.defaultDictationLocaleID)
        #expect(commit.appleTranscript == "bom dia, tudo bem?")
        #expect(snapshot.discardedEntryIDs.isEmpty)
    }

    @Test
    func cancelledLearningRunDiscardsRecording() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let transcriber = FakeTranscriber(.suspended)
        let state = makeState(
            settings: settings,
            transcriber: transcriber,
            recordingArchive: archive
        )

        state.triggerPressed()
        await transcriber.waitForCall()
        state.cancelRequested()
        await expectState(state, .idle)
        await expectArchiveDiscardCount(archive, 1)

        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs == [begunID])
    }

    @Test
    func archiveFinalizationDoesNotDelayDeliveryAndHonorsOptOut() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let recorder = FakeRecorder()
        recorder.finishesStreamOnStop = false
        let archive = SpyRecordingArchive()
        let pasteboard = SpyPasteboard()
        let transcriber = FakeTranscriber(.success("bom dia"))
        let state = makeState(settings: settings, recorder: recorder, transcriber: transcriber,
                              pasteboard: pasteboard, recordingArchive: archive)
        state.triggerPressed()
        await transcriber.waitForCall()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])
        await expectState(state, .idle)
        #expect(await archive.snapshot().commits.isEmpty)

        settings.glossaryLearningEnabled = false
        recorder.finishesStreamOnStop = true
        recorder.stop()
        await expectArchiveDiscardCount(archive, 1)
        #expect(await archive.snapshot().commits.isEmpty)
    }

    @Test
    func learningDisabledNeverTouchesArchive() async {
        let settings = makeTestSettings()
        let archive = SpyRecordingArchive()
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            pasteboard: pasteboard,
            recordingArchive: archive
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        let snapshot = await archive.snapshot()
        #expect(snapshot.begunEntryIDs.isEmpty)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs.isEmpty)
    }

    @Test
    func failedLearningRunNeverPublishesRecording() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let state = makeState(
            settings: settings,
            transformer: FakeTextTransformer(.failure(.transformer)),
            recordingArchive: archive
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectState(state, .error("Something went wrong"))
        await expectArchiveDiscardCount(archive, 1)

        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs == [begunID])
    }

    @Test
    func emptyTranscriptLearningRunLeavesNoRecording() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let state = makeState(
            settings: settings,
            transcriber: FakeTranscriber(.success("  \n")),
            recordingArchive: archive
        )

        state.triggerPressed()
        state.triggerReleased()
        await expectState(state, .error("Nothing heard"))
        await expectArchiveDiscardCount(archive, 1)

        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs == [begunID])
    }

    @Test
    func disablingLearningDuringActiveRunPreventsCommit() async throws {
        let settings = makeTestSettings()
        settings.glossaryLearningEnabled = true
        let archive = SpyRecordingArchive()
        let transcriber = FakeTranscriber(.suspended)
        let pasteboard = SpyPasteboard()
        let state = makeState(
            settings: settings,
            transcriber: transcriber,
            pasteboard: pasteboard,
            recordingArchive: archive
        )

        state.triggerPressed()
        await transcriber.waitForCall()
        settings.glossaryLearningEnabled = false
        await applyGlossaryLearningRetentionChange(
            isEnabled: false,
            settings: settings,
            recordingArchive: archive,
            revertsSettingOnFailure: true
        )
        state.triggerReleased()
        await transcriber.succeed("bom dia, tudo bem?")
        await expectPasteboardWrites(pasteboard, ["Good morning, how are you?"])

        await expectArchiveDiscardCount(archive, 1)
        let snapshot = await archive.snapshot()
        let begunID = try #require(snapshot.begunEntryIDs.first)
        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.discardedEntryIDs == [begunID])
        #expect(snapshot.deleteAllCount == 1)
    }
}
