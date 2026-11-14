import Foundation
import Synchronization
import Testing
@testable import Syrup

/// The two speech-model bugs round 11 reproduced, on the real manager with a real folder. Each fake
/// operation can be held at the point where the bug happens.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SpeechModelRegressionTests {
    /// Delete fails (the folder above the model cannot be written), then the person presses Retry
    /// once it can be: Retry deletes again. It must not load or download the model they asked to delete.
    @Test func retryAfterAFailedDeleteDeletesAgain() async throws {
        let fixture = try RegressionFixture(modelOnDisk: true)
        defer { fixture.clean() }
        try fixture.setRootWritable(false)

        fixture.manager.remove()
        await fixture.manager.waitUntilIdle()
        #expect(fixture.manager.state == .failed("Couldn't remove the model."))

        try fixture.setRootWritable(true)
        fixture.manager.retry()
        await fixture.manager.waitUntilIdle()

        #expect(fixture.manager.state == .notDownloaded)
        #expect(fixture.modelIsOnDisk == false)
        #expect(fixture.calls.values.contains("load") == false)
        #expect(fixture.calls.values.contains("download") == false)
    }

    /// Cancel arrives after the download moved the model into place but before it returned. Once the
    /// work settles, the state must agree with the disk: the model is there, so it is downloaded.
    @Test func cancelAsTheFilesLandLeavesAStateThatAgreesWithTheDisk() async throws {
        let fixture = try RegressionFixture(modelOnDisk: false, holdsAfterLanding: true)
        defer { fixture.clean() }

        fixture.manager.download()
        await fixture.landed.wait()
        fixture.manager.cancelDownload()
        fixture.releaseDownload()
        await fixture.manager.waitUntilIdle()

        #expect(fixture.modelIsOnDisk)
        #expect(fixture.manager.state == .downloaded)
    }

    /// Load, then Delete before the load has started: the load is skipped, so the Delete does not wait
    /// for a model to load (minutes for some models) only to unload it.
    @Test func deleteRightAfterALoadRequestSkipsTheLoad() async throws {
        let fixture = try RegressionFixture(modelOnDisk: true)
        defer { fixture.clean() }

        fixture.manager.loadIfDownloaded()
        fixture.manager.remove()
        await fixture.manager.waitUntilIdle()

        #expect(fixture.calls.values == ["unload"])
        #expect(fixture.manager.state == .notDownloaded)
        #expect(fixture.modelIsOnDisk == false)
    }

    /// Download, then Cancel before the download has started: nothing is downloaded.
    @Test func cancelRightAfterDownloadDownloadsNothing() async throws {
        let fixture = try RegressionFixture(modelOnDisk: false)
        defer { fixture.clean() }

        fixture.manager.download()
        fixture.manager.cancelDownload()
        await fixture.manager.waitUntilIdle()

        #expect(fixture.calls.values.isEmpty)
        #expect(fixture.manager.state == .notDownloaded)
        #expect(fixture.modelIsOnDisk == false)
    }

    /// A click must never come between the manager deciding that a job still runs and the job's work
    /// starting, or the job does its work after the click made it stale. The fakes here run on the
    /// main actor, as clicks do, so the check and the start of the work happen in one turn unless the
    /// manager schedules something between them. Attempts yield zero to five times before clicking,
    /// so the click lands at each point of the job's start. (With fakes off the main actor, a click can also come while the call travels to the
    /// fake, after the work has already been committed to, in every version; that is not this bug.)
    @Test(arguments: ["load", "download", "loadAfterDownload"])
    func aJobOvertakenAfterItBeganDoesNoWork(_ kind: String) async throws {
        var stale = 0
        for attempt in 0..<120 {
            let yields = attempt % 6
            let fixture = try RegressionFixture(modelOnDisk: kind == "load", holdsAfterLanding: kind == "loadAfterDownload", operationsOnMainActor: true)
            defer { fixture.clean() }
            switch kind {
            case "load":
                fixture.manager.loadIfDownloaded()
                for _ in 0..<yields { await Task.yield() }
                fixture.calls.append("click")
                fixture.manager.remove()
            case "download":
                fixture.manager.download()
                for _ in 0..<yields { await Task.yield() }
                fixture.calls.append("click")
                fixture.manager.cancelDownload()
            default:
                // Held after landing, then let go, so the follow-up load starts a known number of
                // turns before the click.
                fixture.manager.download()
                await eventually { fixture.landed.isFired }
                fixture.releaseDownload()
                for _ in 0..<yields { await Task.yield() }
                fixture.calls.append("click")
                fixture.manager.remove()
            }
            await fixture.manager.waitUntilIdle()
            let calls = fixture.calls.values
            guard let click = calls.firstIndex(of: "click") else { continue }
            let late = kind == "download" ? "download" : "load"
            if calls[(click + 1)...].contains(late) { stale += 1 }
        }
        #expect(stale == 0, "\(stale) of 120 \(kind) jobs did their work after a click made them stale")
    }

    /// The handover from an older folder when the model is already on disk deletes the older folder
    /// at once and downloads nothing. (The conformance test does not replay this start, since it
    /// explores the same states as a model on disk without a handover; the explorer covers it.)
    @Test func replacingWithTheModelAlreadyOnDiskDeletesTheOlderFolderAtOnce() async throws {
        let fixture = try RegressionFixture(modelOnDisk: true)
        defer { fixture.clean() }
        let older = fixture.root.appending(path: SpeechEngine.retiredParakeetV3Folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)

        fixture.manager.replace(older)

        #expect(FileManager.default.fileExists(atPath: older.path(percentEncoded: false)) == false)
        #expect(fixture.manager.state == .downloaded)
        await fixture.manager.waitUntilIdle()
        #expect(fixture.calls.values.isEmpty)
    }

    /// A cancelled download keeps its finished files in staging for the next attempt. The manager
    /// reports them, at once and at the next launch, so Settings can offer to delete them, and Delete
    /// removes them.
    @Test func aPartialDownloadIsReportedAndDeleteRemovesIt() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelPartial"), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Signal()
        let operations = SpeechModelManager.Operations(
            modelsExist: { RegressionFixture.isComplete($0) },
            download: { directory, _ in
                // As the live download does: files arrive in staging, and the model moves into place
                // only when complete.
                let staging = SpeechModelManager.stagingDirectory(for: directory)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try Data("part".utf8).write(to: staging.appending(path: "part"))
                started.fire()
                try await Task.sleep(for: .seconds(3_600))
            },
            load: { _ in },
            unload: {}
        )
        let manager = SpeechModelManager(engine: .parakeetUltra, operations: operations, isSupported: true, storageDirectory: root)
        let staging = SpeechModelManager.stagingDirectory(for: manager.directory)
        #expect(manager.hasPartialDownload == false)

        manager.download()
        await started.wait()
        manager.cancelDownload()
        await manager.waitUntilIdle()
        #expect(manager.state == .notDownloaded)
        #expect(manager.hasPartialDownload)
        let relaunched = SpeechModelManager(engine: .parakeetUltra, operations: operations, isSupported: true, storageDirectory: root)
        #expect(relaunched.hasPartialDownload)

        manager.remove()
        await manager.waitUntilIdle()
        #expect(manager.hasPartialDownload == false)
        #expect(FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)) == false)
        #expect(manager.state == .notDownloaded)
    }

    /// A cancelled download that is slow to stop reports progress after the next download started:
    /// the next download's bar must not move. Its own report does move it.
    @Test func lateProgressFromACancelledDownloadDoesNotMoveTheNextOne() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelProgress"), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let reporters = Mutex<[@Sendable (Double) -> Void]>([])
        let firstStarted = Signal(), releaseFirst = Signal(), secondStarted = Signal(), releaseSecond = Signal()
        let manager = SpeechModelManager(
            engine: .parakeetUltra,
            operations: .init(
                modelsExist: { _ in false },
                download: { _, report in
                    let call = reporters.withLock { reporters in
                        reporters.append(report)
                        return reporters.count
                    }
                    if call == 1 {
                        firstStarted.fire()
                        await releaseFirst.wait()
                        throw CancellationError()
                    }
                    secondStarted.fire()
                    await releaseSecond.wait()
                    throw CocoaError(.fileWriteUnknown)
                },
                load: { _ in },
                unload: {}
            ),
            isSupported: true,
            storageDirectory: root
        )

        manager.download()
        await firstStarted.wait()
        manager.cancelDownload()
        manager.download()
        releaseFirst.fire()
        await secondStarted.wait()

        let (first, second) = reporters.withLock { ($0[0], $0[1]) }
        first(0.9)
        await Task { @MainActor in }.value
        #expect(manager.state == .downloading(0))
        second(0.4)
        await eventually { manager.state == .downloading(0.4) }
        #expect(manager.state == .downloading(0.4))

        releaseSecond.fire()
        await manager.waitUntilIdle()
    }
}

/// A model folder with a marker file. The download writes the marker into place and, if asked, then
/// holds until released, ignoring cancellation, as a real download does once its files have moved.
@MainActor
final class RegressionFixture {
    let root: URL
    let manager: SpeechModelManager
    let calls = CallRecord()
    let landed = Signal()
    private let release = Signal()

    var modelIsOnDisk: Bool { Self.isComplete(manager.directory) }

    /// `operationsOnMainActor`: the download and load start on the main actor, so no click can come
    /// between the manager calling them and their first line.
    init(modelOnDisk: Bool, holdsAfterLanding: Bool = false, operationsOnMainActor: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelRegression"), directoryHint: .isDirectory)
        self.root = root
        let directory = root.appending(path: SpeechEngine.parakeetUltra.modelFolder ?? "model", directoryHint: .isDirectory)
        if modelOnDisk { try Self.writeModel(at: directory) }
        let calls = calls, landed = landed, release = release
        let downloadWork: @Sendable (URL) async throws -> Void = { directory in
            try Self.writeModel(at: directory)
            landed.fire()
            if holdsAfterLanding { await release.wait() }
        }
        let loadWork: @Sendable (URL) async throws -> Void = { directory in
            guard Self.isComplete(directory) else { throw CocoaError(.fileReadNoSuchFile) }
        }
        // Each logs its call as its first line, so on the main actor the log is written in the same
        // turn as the call.
        let download: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void
        let load: @Sendable (URL) async throws -> Void
        if operationsOnMainActor {
            download = { @MainActor (directory: URL, _: @escaping @Sendable (Double) -> Void) async throws in
                calls.append("download")
                try await downloadWork(directory)
            }
            load = { @MainActor (directory: URL) async throws in
                calls.append("load")
                try await loadWork(directory)
            }
        } else {
            download = { directory, _ in
                calls.append("download")
                try await downloadWork(directory)
            }
            load = { directory in
                calls.append("load")
                try await loadWork(directory)
            }
        }
        manager = SpeechModelManager(
            engine: .parakeetUltra,
            operations: .init(
                modelsExist: { Self.isComplete($0) },
                download: download,
                load: load,
                unload: { calls.append("unload") }
            ),
            isSupported: true,
            storageDirectory: root
        )
    }

    func releaseDownload() { release.fire() }

    func setRootWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o700 : 0o500], ofItemAtPath: root.path(percentEncoded: false))
    }

    func clean() {
        try? setRootWritable(true)
        try? FileManager.default.removeItem(at: root)
    }

    nonisolated static func isComplete(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: "weights.bin").path(percentEncoded: false))
    }

    nonisolated static func writeModel(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: directory.appending(path: "weights.bin"))
    }
}

final class CallRecord: Sendable {
    private let entries = Mutex<[String]>([])
    var values: [String] { entries.withLock { $0 } }
    func append(_ call: String) { entries.withLock { $0.append(call) } }
}

/// Fires once; waiting after it fired returns at once. Waiting is not cut short by cancellation.
final class Signal: Sendable {
    private let state = Mutex<(fired: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))
    var isFired: Bool { state.withLock { $0.fired } }

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                if state.fired { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
