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

    init(modelOnDisk: Bool, holdsAfterLanding: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelRegression"), directoryHint: .isDirectory)
        self.root = root
        let directory = root.appending(path: SpeechEngine.parakeetUltra.modelFolder ?? "model", directoryHint: .isDirectory)
        if modelOnDisk { try Self.writeModel(at: directory) }
        let calls = calls, landed = landed, release = release
        manager = SpeechModelManager(
            engine: .parakeetUltra,
            operations: .init(
                modelsExist: { Self.isComplete($0) },
                download: { directory, _ in
                    calls.append("download")
                    try Self.writeModel(at: directory)
                    landed.fire()
                    if holdsAfterLanding { await release.wait() }
                },
                load: { directory in
                    calls.append("load")
                    guard Self.isComplete(directory) else { throw CocoaError(.fileReadNoSuchFile) }
                },
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
