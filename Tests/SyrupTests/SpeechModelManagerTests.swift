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

    @Test func removeUnloadsAndDeletesTheModel() async throws {
        let fixture = try Fixture(onDisk: true)
        fixture.manager.loadIfDownloaded()
        await waitFor(.ready, in: fixture.manager)
        fixture.manager.remove()
        await waitFor(.notDownloaded, in: fixture.manager)
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
        await waitFor(.notDownloaded, in: fixture.manager)
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
        #expect(fileManager.fileExists(atPath: retired.path(percentEncoded: false)) == false)
        #expect(fileManager.fileExists(atPath: sibling.path(percentEncoded: false)))
        #expect(fixture.manager.state == .downloading(0))
        await fixture.gate.open()
        await waitFor(.ready, in: fixture.manager)
        #expect(fixture.log.calls == ["download", "load"])
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

    init(onDisk: Bool, isSupported: Bool = true, progress: [Double] = [], failingDownloads: Int = 0) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelManagerTests"), directoryHint: .isDirectory)
        let log = CallLog(), gate = Gate()
        self.root = root
        self.log = log
        self.gate = gate
        let onDiskFlag = Mutex(onDisk)
        let progressLog = CallLog()
        self.progressLog = progressLog
        let failures = Mutex(failingDownloads)
        manager = SpeechModelManager(
            engine: .parakeetUltra,
            operations: .init(
                modelsExist: { _ in onDiskFlag.withLock { $0 } },
                download: { directory, report in
                    log.record("download")
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
                load: { _ in log.record("load") },
                unload: { log.record("unload") }
            ),
            isSupported: isSupported,
            storageDirectory: root
        )
        if onDisk {
            try FileManager.default.createDirectory(at: manager.directory, withIntermediateDirectories: true)
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
