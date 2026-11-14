import Foundation
import Observation

/// One downloadable speech model. `SpeechModelMachine` decides; this runs what it decides: it sends
/// each click and each finished job to the machine, and starts the jobs, cancels the download, and
/// deletes folders as the machine's effects say.
@MainActor
@Observable
final class SpeechModelManager: SpeechModelProviding {
    struct Operations: Sendable {
        var modelsExist: @Sendable (URL) -> Bool
        var download: @Sendable (URL, @escaping @Sendable (Double) -> Void) async throws -> Void
        var load: @Sendable (URL) async throws -> Void
        var unload: @Sendable () async -> Void
        /// Runs as each job's task begins, before the machine decides whether the job still runs.
        /// Tests hold it to put clicks between a job being queued and starting.
        var willBeginJob: @Sendable () async -> Void = {}
    }

    let engine: SpeechEngine
    private(set) var state: SpeechModelState
    /// Files a cancelled or failed download left in staging for the next attempt. Read at launch and
    /// whenever the work drains, so Settings can offer to delete them.
    private(set) var hasPartialDownload: Bool
    let directory: URL
    @ObservationIgnored private let operations: Operations
    @ObservationIgnored private let fileManager: FileManager
    @ObservationIgnored private var machine: SpeechModelMachine
    /// The task of the job the machine is running, from its start to its finish. Jobs run one at a
    /// time, in the machine's order. One task per job: it asks the machine whether the job still
    /// runs and calls the operation without a suspension in between, so no click can come between
    /// the check and the call. The call itself leaves the main actor, and a click can arrive while
    /// it does, after the work was committed to, as it could in the old manager.
    @ObservationIgnored private var runningTask: Task<Void, Never>?
    /// A folder this model is taking over from; see `replace`.
    @ObservationIgnored private var replacedDirectory: URL?

    init(
        engine: SpeechEngine,
        operations: Operations,
        isSupported: Bool,
        storageDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let storageDirectory = storageDirectory ?? Self.defaultStorageDirectory(fileManager: fileManager)
        self.engine = engine
        self.operations = operations
        self.fileManager = fileManager
        directory = storageDirectory.appending(path: engine.modelFolder ?? engine.rawValue, directoryHint: .isDirectory)
        let state: SpeechModelState = if isSupported == false {
            .unsupported
        } else {
            operations.modelsExist(directory) ? .downloaded : .notDownloaded
        }
        self.state = state
        hasPartialDownload = fileManager.fileExists(atPath: Self.stagingDirectory(for: directory).path(percentEncoded: false))
        machine = SpeechModelMachine(state: state)
    }

    /// Unfinished downloads wait here, beside the model, so they can resume and are removed with it.
    nonisolated static func stagingDirectory(for directory: URL) -> URL {
        directory.deletingLastPathComponent().appending(
            path: ".partial-\(directory.lastPathComponent)", directoryHint: .isDirectory
        )
    }

    func download() {
        send(.download)
    }

    /// Stops a download in progress. Files that finished stay in the staging folder, so the next
    /// download can keep them; it starts once this one has stopped. A handover this download was
    /// making (see `replace`) ends too.
    func cancelDownload() {
        send(.cancelDownload)
    }

    /// Takes over from an older model's folder: downloads this model if it is missing and deletes the
    /// older folder once this one is on disk. If the download fails, the older folder stays and the
    /// next launch tries again. If the person cancels or deletes this model instead, the older
    /// folder goes too, so a handover they stopped does not start again at every launch.
    func replace(_ olderDirectory: URL) {
        replacedDirectory = olderDirectory
        send(.replace)
    }

    /// Retry after a failure repeats what failed: a removal, a load, or a download.
    func retry() {
        guard case .failed = state else { return }
        send(.retry(modelOnDisk: operations.modelsExist(directory)))
    }

    /// Runs at every dictation trigger, so it reads nothing from the disk.
    func loadIfDownloaded() {
        send(.loadIfDownloaded)
    }

    /// Deletes the model, its unfinished download, and any folder it was replacing. A download in
    /// progress is cancelled first, and a load in progress is let finish without becoming ready; the
    /// folders go once they have stopped. The model shows as not downloaded at once, so nothing can
    /// start loading it meanwhile. An accepted Delete always removes the files, even if a later
    /// Download, which waits its turn behind it, has changed what the state should show.
    func remove() {
        send(.remove)
    }

    /// Waits until every queued download, load, and removal has finished, including any queued
    /// meanwhile.
    func waitUntilIdle() async {
        while let task = runningTask {
            await task.value
            // A finished task always hands over or clears `runningTask` before it ends; if it did
            // not, stop rather than spin on a task that is already done.
            if runningTask == task { return }
        }
    }

    /// Returns every effect the event led to.
    @discardableResult
    private func send(_ event: SpeechModelMachine.Event) -> [SpeechModelMachine.Effect] {
        var events = [event]
        var handled: [SpeechModelMachine.Effect] = []
        while events.isEmpty == false {
            let effects = machine.handle(events.removeFirst())
            handled += effects
            for effect in effects {
                switch effect {
                case .start(let job):
                    runningTask = Task {
                        await operations.willBeginJob()
                        // Sent even when this task was cancelled: the machine waits for it to skip or
                        // run the job, and nothing else would move it on.
                        guard send(.began(job)).contains(.perform(job)) else { return }
                        let outcome = await run(job)
                        send(.finished(job, outcome))
                    }
                case .perform:
                    // Run by the job's own task, right after `.began`.
                    break
                case .cancelRunningDownload:
                    runningTask?.cancel()
                case .removeReplacedDirectory:
                    removeReplacedDirectory()
                case .checkDisk:
                    events.append(.settled(modelOnDisk: operations.modelsExist(directory)))
                    let partial = fileManager.fileExists(atPath: Self.stagingDirectory(for: directory).path(percentEncoded: false))
                    if hasPartialDownload != partial { hasPartialDownload = partial }
                }
            }
        }
        if machine.running == nil { runningTask = nil }
        if state != machine.state { state = machine.state }
        return handled
    }

    private func run(_ job: SpeechModelMachine.Job) async -> SpeechModelMachine.Outcome {
        let directory = directory
        do {
            switch job.operation {
            case .download:
                try protectStorageDirectory()
                try await operations.download(directory) { fraction in
                    Task { @MainActor in self.send(.progress(fraction, generation: job.generation)) }
                }
            case .load:
                try await operations.load(directory)
            case .removal:
                await operations.unload()
                for folder in [directory, Self.stagingDirectory(for: directory)]
                where fileManager.fileExists(atPath: folder.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: folder)
                }
            }
            return .succeeded
        } catch {
            return .failed
        }
    }

    private func removeReplacedDirectory() {
        guard let replacedDirectory else { return }
        self.replacedDirectory = nil
        try? fileManager.removeItem(at: replacedDirectory)
    }

    private func protectStorageDirectory() throws {
        let parent = directory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path(percentEncoded: false))
    }

    private static func defaultStorageDirectory(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appending(path: "Syrup", directoryHint: .isDirectory)
            .appending(path: "SpeechModels", directoryHint: .isDirectory)
    }
}
