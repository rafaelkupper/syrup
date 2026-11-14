import Foundation
import Synchronization
import Testing
@testable import Syrup

@MainActor
struct SpeechModelManagerTests {
    @Test func loadIfDownloadedNeverDownloads() async throws {
        let fixture = try Fixture(onDisk: false)
        fixture.manager.loadIfDownloaded()
        #expect(fixture.manager.state == .notDownloaded)
        #expect(fixture.log.calls == [])
    }

    @Test func loadIfDownloadedLoadsAModelAlreadyOnDisk() async throws {
        let fixture = try Fixture(onDisk: true)
        #expect(fixture.manager.state == .downloaded)
        fixture.manager.loadIfDownloaded()
        await waitFor(.ready, in: fixture.manager)
        #expect(fixture.log.calls == ["load"])
    }

    @Test func downloadIsExplicitReportsProgressAndLoads() async throws {
        let fixture = try Fixture(onDisk: false, progress: [0.5, 0.2])
        fixture.manager.download()
        await waitFor(.downloading(0.5), in: fixture.manager)
        // Both reports are queued on the main actor once the download has made them; one more hop
        // runs after them, so the lower 0.2 has been handled by the time it returns.
        await eventually { fixture.progressLog.calls.isEmpty == false }
        await Task { @MainActor in }.value
        #expect(fixture.manager.state == .downloading(0.5))
        await fixture.gate.open()
        await waitFor(.ready, in: fixture.manager)
        #expect(fixture.log.calls == ["download", "load"])
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.root.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(fixture.manager.directory.deletingLastPathComponent() == fixture.root)
    }

    @Test func failuresAreReportedAndRetryable() async throws {
        let fixture = try Fixture(onDisk: false, failingDownloads: 1)
        await fixture.gate.open()
        fixture.manager.download()
        await waitFor(.failed("Download failed."), in: fixture.manager)
        fixture.manager.download()
        await waitFor(.ready, in: fixture.manager)
        #expect(fixture.log.calls == ["download", "download", "load"])
    }

    @Test func retryAfterALoadFailureLoadsAgainInsteadOfDownloading() async throws {
        let fixture = try Fixture(onDisk: true, failingLoads: 1)
        fixture.manager.loadIfDownloaded()
        await waitFor(.failed("The model couldn't load."), in: fixture.manager)
        fixture.manager.retry()
        await waitFor(.ready, in: fixture.manager)
        #expect(fixture.log.calls == ["load", "load"])
    }

    @Test func retryAfterADownloadFailureDownloadsAgain() async throws {
        let fixture = try Fixture(onDisk: false, failingDownloads: 1)
        await fixture.gate.open()
        fixture.manager.download()
        await waitFor(.failed("Download failed."), in: fixture.manager)
        fixture.manager.retry()
        await waitFor(.ready, in: fixture.manager)
        #expect(fixture.log.calls == ["download", "download", "load"])
    }

    @Test func removeUnloadsAndDeletesTheModel() async throws {
        let fixture = try Fixture(onDisk: true)
        fixture.manager.loadIfDownloaded()
        await waitFor(.ready, in: fixture.manager)
        fixture.manager.remove()
        // Delete shows the model as not downloaded at once; the files go once it is unloaded.
        #expect(fixture.manager.state == .notDownloaded)
        await eventually { FileManager.default.fileExists(atPath: fixture.manager.directory.path(percentEncoded: false)) == false }
        #expect(fixture.log.calls == ["load", "unload"])
        #expect(FileManager.default.fileExists(atPath: fixture.manager.directory.path(percentEncoded: false)) == false)
    }

    @Test func removeLeavesOtherModelsInPlaceAndClearsItsUnfinishedDownload() async throws {
        let fixture = try Fixture(onDisk: true)
        let fileManager = FileManager.default
        let sibling = fixture.root.appending(path: "nemotron-multilingual", directoryHint: .isDirectory)
        let staging = SpeechModelManager.stagingDirectory(for: fixture.manager.directory)
        for folder in [fixture.manager.directory, sibling, staging] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        fixture.manager.remove()
        await eventually { fileManager.fileExists(atPath: staging.path(percentEncoded: false)) == false }
        #expect(fixture.manager.state == .notDownloaded)
        #expect(fileManager.fileExists(atPath: sibling.path(percentEncoded: false)))
        #expect(fileManager.fileExists(atPath: fixture.manager.directory.path(percentEncoded: false)) == false)
        #expect(fileManager.fileExists(atPath: staging.path(percentEncoded: false)) == false)
    }

    @Test func aParakeetV3DownloadIsRemovedAndUltraDownloadsInItsPlace() async throws {
        let fixture = try Fixture(onDisk: false)
        let fileManager = FileManager.default
        let retired = fixture.root.appending(path: SpeechEngine.retiredParakeetV3Folder, directoryHint: .isDirectory)
        let sibling = fixture.root.appending(path: "parakeet-redux", directoryHint: .isDirectory)
        for folder in [retired, sibling] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: folder.appending(path: "Encoder.bin"))
        }
        SpeechModelCatalog(managers: [.parakeetUltra: fixture.manager], transcribers: [:]).replaceRetiredParakeetV3()
        // v3 stays until Ultra is on disk.
        #expect(fileManager.fileExists(atPath: retired.path(percentEncoded: false)))
        #expect(fixture.manager.state == .downloading(0))
        await fixture.gate.open()
        await waitFor(.ready, in: fixture.manager)
        #expect(fileManager.fileExists(atPath: retired.path(percentEncoded: false)) == false)
        #expect(fileManager.fileExists(atPath: sibling.path(percentEncoded: false)))
        #expect(fixture.log.calls == ["download", "load"])
    }

    /// An incomplete folder already at the destination is replaced, instead of failing the move on
    /// every retry. A complete model is never downloaded, so it is never replaced.
    @Test func aDownloadReplacesAnIncompleteModelFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelStaging"), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "model", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: directory.appending(path: "leftover.bin"))
        let complete: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.appending(path: "weights.bin").path(percentEncoded: false)) }

        try await SpeechModelCatalog.stagedDownload(into: directory, modelsExist: complete, download: { staging, _ in
            let model = staging.appending(path: "model", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data("weights".utf8).write(to: model.appending(path: "weights.bin"))
        }, progress: { _ in })

        #expect(complete(directory))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "leftover.bin").path(percentEncoded: false)) == false)
        #expect(FileManager.default.fileExists(atPath: SpeechModelManager.stagingDirectory(for: directory).path(percentEncoded: false)) == false)
    }

    @Test func aCompleteModelAtTheDestinationIsKeptAndNothingDownloads() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelStaging"), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appending(path: "model", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: directory.appending(path: "weights.bin"))
        let complete: @Sendable (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.appending(path: "weights.bin").path(percentEncoded: false)) }
        let downloads = CallLog()

        try await SpeechModelCatalog.stagedDownload(into: directory, modelsExist: complete, download: { _, _ in
            downloads.record("download")
        }, progress: { _ in })

        #expect(downloads.calls == [])
        #expect(complete(directory))
    }

    @Test func cancelStopsTheDownload() async throws {
        let fixture = try Fixture(onDisk: false, downloadsWaitForCancel: true)
        fixture.manager.download()
        await eventually { fixture.log.calls == ["download"] }
        fixture.manager.cancelDownload()
        #expect(fixture.manager.state == .notDownloaded)
        await eventually { fixture.log.calls == ["download", "download cancelled"] }
        #expect(fixture.log.calls == ["download", "download cancelled"])
    }

    /// A cancelled download that is slow to stop: it holds on until the next download starts, or
    /// 300 ms. The next download must wait for it, since both use the same staging folder.
    @Test func aNewDownloadWaitsForACancelledOneToStop() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelOverlap"), directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = OverlapLog()
        let secondStarted = AsyncStream<Void>.makeStream()
        let manager = SpeechModelManager(
            engine: .parakeetUltra,
            operations: .init(
                modelsExist: { _ in false },
                download: { _, _ in
                    let call = downloads.begin()
                    defer { downloads.end() }
                    guard call == 1 else {
                        secondStarted.continuation.yield()
                        return
                    }
                    do {
                        try await Task.sleep(for: .seconds(3_600))
                    } catch {
                        // A task of its own, which the download's cancellation does not reach, as a
                        // real downloader finishing a file write is not cut short.
                        await Task {
                            await withTaskGroup(of: Void.self) { group in
                                group.addTask { for await _ in secondStarted.stream { return } }
                                group.addTask { try? await Task.sleep(for: .milliseconds(300)) }
                                await group.next()
                                group.cancelAll()
                            }
                        }.value
                        throw error
                    }
                },
                load: { _ in },
                unload: {}
            ),
            isSupported: true,
            storageDirectory: root
        )
        manager.download()
        await eventually { downloads.calls == 1 }
        manager.cancelDownload()
        manager.download()
        await waitFor(.ready, in: manager)
        #expect(downloads.calls == 2)
        #expect(downloads.mostAtOnce == 1)
    }

    /// A workflow change asks for a load right after Delete. The model shows as not downloaded at
    /// once, so no load starts and the files go.
    @Test func aLoadAskedForRightAfterDeleteDoesNotKeepTheModel() async throws {
        let fixture = try Fixture(onDisk: true)
        fixture.manager.remove()
        fixture.manager.loadIfDownloaded()
        await eventually { FileManager.default.fileExists(atPath: fixture.manager.directory.path(percentEncoded: false)) == false }
        #expect(fixture.manager.state == .notDownloaded)
        #expect(fixture.log.calls == ["unload"])
    }

    /// Delete while a load is under way: the load is held inside the backend, so it has started. It
    /// is not let become ready, and the files still go.
    @Test func deleteDuringAStartedLoadStillRemovesTheModel() async throws {
        let loadGate = Gate()
        let fixture = try Fixture(onDisk: true, loadGate: loadGate)
        fixture.manager.loadIfDownloaded()
        await eventually { fixture.log.calls == ["load"] }
        fixture.manager.remove()
        #expect(fixture.manager.state == .notDownloaded)
        await loadGate.open()
        await fixture.manager.waitUntilIdle()
        #expect(FileManager.default.fileExists(atPath: fixture.manager.directory.path(percentEncoded: false)) == false)
        #expect(fixture.manager.state == .notDownloaded)
        #expect(fixture.log.calls == ["load", "unload"])
    }

    /// Download pressed right after Delete, while the model is still unloading: the deletion goes
    /// first, so the download starts with no model on disk instead of reusing the deleted one.
    @Test func downloadRightAfterDeleteStartsFromNothing() async throws {
        let unloadGate = Gate()
        let fixture = try Fixture(onDisk: true, unloadGate: unloadGate)
        await fixture.gate.open()
        fixture.manager.remove()
        fixture.manager.download()
        await unloadGate.open()
        await fixture.manager.waitUntilIdle()
        #expect(fixture.downloadsFoundAModel.values == [false])
        #expect(fixture.log.calls == ["unload", "download", "load"])
        #expect(fixture.manager.state == .ready)
    }

    @Test func deleteWhileDownloadingCancelsTheDownloadThenRemovesWhatItFetched() async throws {
        let fixture = try Fixture(onDisk: false, downloadsWaitForCancel: true)
        let staging = SpeechModelManager.stagingDirectory(for: fixture.manager.directory)
        fixture.manager.download()
        await eventually { fixture.log.calls == ["download"] }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        fixture.manager.remove()
        await eventually { fixture.log.calls.count == 3 }
        await eventually { FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)) == false }
        #expect(fixture.log.calls == ["download", "download cancelled", "unload"])
        #expect(FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)) == false)
        #expect(fixture.manager.state == .notDownloaded)
    }

    /// Without this, the handover would start the 632 MB download again at every launch.
    @Test func cancellingTheUltraHandoverDeletesV3SoTheNextLaunchDoesNotStartItAgain() async throws {
        let fixture = try Fixture(onDisk: false, downloadsWaitForCancel: true)
        let retired = fixture.root.appending(path: SpeechEngine.retiredParakeetV3Folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let catalog = SpeechModelCatalog(managers: [.parakeetUltra: fixture.manager], transcribers: [:])
        catalog.replaceRetiredParakeetV3()
        #expect(fixture.manager.state == .downloading(0))
        fixture.manager.cancelDownload()
        #expect(FileManager.default.fileExists(atPath: retired.path(percentEncoded: false)) == false)

        catalog.replaceRetiredParakeetV3()
        #expect(fixture.manager.state == .notDownloaded)
    }

    @Test func aFailedUltraDownloadKeepsParakeetV3SoTheNextLaunchTriesAgain() async throws {
        let fixture = try Fixture(onDisk: false, failingDownloads: 1)
        let retired = fixture.root.appending(path: SpeechEngine.retiredParakeetV3Folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let catalog = SpeechModelCatalog(managers: [.parakeetUltra: fixture.manager], transcribers: [:])
        catalog.replaceRetiredParakeetV3()
        await fixture.gate.open()
        await waitFor(.failed("Download failed."), in: fixture.manager)
        #expect(FileManager.default.fileExists(atPath: retired.path(percentEncoded: false)))

        catalog.replaceRetiredParakeetV3()
        await waitFor(.ready, in: fixture.manager)
        #expect(FileManager.default.fileExists(atPath: retired.path(percentEncoded: false)) == false)
    }

    @Test func withoutAParakeetV3DownloadNothingDownloads() async throws {
        let fixture = try Fixture(onDisk: false)
        SpeechModelCatalog(managers: [.parakeetUltra: fixture.manager], transcribers: [:]).replaceRetiredParakeetV3()
        #expect(fixture.manager.state == .notDownloaded)
        #expect(fixture.log.calls == [])
    }

    @Test func unsupportedMacsNeverDownloadOrLoad() async throws {
        let fixture = try Fixture(onDisk: true, isSupported: false)
        fixture.manager.download()
        fixture.manager.loadIfDownloaded()
        #expect(fixture.manager.state == .unsupported)
        #expect(fixture.log.calls == [])
    }

    private func waitFor(_ expected: SpeechModelState, in manager: SpeechModelManager) async {
        await eventually { manager.state == expected }
        #expect(manager.state == expected)
    }
}

/// Counts downloads and the most that ran at the same time.
private final class OverlapLog: Sendable {
    private let state = Mutex((calls: 0, running: 0, mostAtOnce: 0))
    var calls: Int { state.withLock { $0.calls } }
    var mostAtOnce: Int { state.withLock { $0.mostAtOnce } }

    func begin() -> Int {
        state.withLock {
            $0.calls += 1
            $0.running += 1
            $0.mostAtOnce = max($0.mostAtOnce, $0.running)
            return $0.calls
        }
    }

    func end() {
        state.withLock { $0.running -= 1 }
    }
}

private final class Recorded<Value: Sendable>: Sendable {
    private let entries = Mutex<[Value]>([])
    var values: [Value] { entries.withLock { $0 } }
    func append(_ value: Value) { entries.withLock { $0.append(value) } }
}

private final class CallLog: Sendable {
    private let entries = Mutex<[String]>([])
    var calls: [String] { entries.withLock { $0 } }
    func record(_ call: String) { entries.withLock { $0.append(call) } }
}

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let log: CallLog
    let gate: Gate
    let manager: SpeechModelManager
    /// Records "reported" once the fake download has made all its progress reports.
    let progressLog: CallLog
    /// For each download, whether a model was on disk when it started.
    let downloadsFoundAModel = Recorded<Bool>()

    /// `downloadsWaitForCancel`: a download stays in progress until its task is cancelled.
    init(
        onDisk: Bool, isSupported: Bool = true, progress: [Double] = [], failingDownloads: Int = 0, failingLoads: Int = 0,
        downloadsWaitForCancel: Bool = false, loadGate: Gate? = nil, unloadGate: Gate? = nil
    ) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelManagerTests"), directoryHint: .isDirectory)
        let log = CallLog(), gate = Gate()
        self.root = root
        self.log = log
        self.gate = gate
        let onDiskFlag = Mutex(onDisk)
        let progressLog = CallLog()
        self.progressLog = progressLog
        let failures = Mutex(failingDownloads)
        let loadFailures = Mutex(failingLoads)
        if onDisk {
            // Before the manager reads it, as a model left by an earlier launch would be.
            let engine = SpeechEngine.parakeetUltra
            try FileManager.default.createDirectory(
                at: root.appending(path: engine.modelFolder ?? engine.rawValue, directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )
        }
        manager = SpeechModelManager(
            engine: .parakeetUltra,
            operations: .init(
                // Like the real check, it reads the folder too, so a Delete that removed it is seen.
                modelsExist: { directory in
                    onDiskFlag.withLock { $0 } && FileManager.default.fileExists(atPath: directory.path(percentEncoded: false))
                },
                download: { [downloadsFoundAModel] directory, report in
                    downloadsFoundAModel.append(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
                    log.record("download")
                    if downloadsWaitForCancel {
                        do {
                            try await Task.sleep(for: .seconds(3_600))
                        } catch {
                            log.record("download cancelled")
                            throw error
                        }
                    }
                    if failures.withLock({ count in
                        count -= 1
                        return count >= 0
                    }) {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    progress.forEach(report)
                    progressLog.record("reported")
                    await gate.wait()
                    onDiskFlag.withLock { $0 = true }
                },
                load: { _ in
                    log.record("load")
                    await loadGate?.wait()
                    if loadFailures.withLock({ count in
                        count -= 1
                        return count >= 0
                    }) {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                },
                unload: {
                    log.record("unload")
                    await unloadGate?.wait()
                }
            ),
            isSupported: isSupported,
            storageDirectory: root
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
