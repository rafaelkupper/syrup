import Foundation

/// The rules of `SpeechModelManager`, as a pure function from events to a new state and the effects
/// to run. Nothing here touches the disk or starts work, so a test can run every interleaving of
/// clicks and completions against it (`SpeechModelExplorerTests`).
///
/// Work runs one job at a time, in order: a download, a load, or a removal. Each user action that
/// changes what the person asked for moves `generation` on, and a job from an earlier generation is
/// stale: its result no longer changes the state, and a stale download or load that has not started
/// yet is skipped. A removal always runs, because a Delete the person made must take the files.
struct SpeechModelMachine: Equatable, Sendable {
    enum Operation: Equatable, Sendable {
        case download, load, removal
    }

    struct Job: Equatable, Sendable {
        let operation: Operation
        let generation: Int
    }

    enum Failure: Equatable, Sendable {
        case download, load, removal
    }

    enum Outcome: Equatable, Sendable {
        case succeeded, failed
    }

    enum Event: Equatable, Sendable {
        case download
        case cancelDownload
        /// The manager is taking over from an older model's folder (`SpeechModelManager.replace`).
        case replace
        case retry(modelOnDisk: Bool)
        case loadIfDownloaded
        case remove
        case progress(Double, generation: Int)
        case finished(Job, Outcome)
        /// The disk, read when the work has drained (`Effect.checkDisk`).
        case settled(modelOnDisk: Bool)
    }

    enum Effect: Equatable, Sendable {
        case start(Job)
        case cancelRunningDownload
        case removeReplacedDirectory
        /// Read whether the model is on disk and send `.settled`.
        case checkDisk
    }

    static let downloadFailed = "Download failed."
    static let loadFailed = "The model couldn't load."
    static let removalFailed = "Couldn't remove the model."

    private(set) var state: SpeechModelState
    private(set) var generation = 0
    private(set) var failure: Failure?
    private(set) var running: Job?
    private(set) var queue: [Job] = []
    private(set) var handoverPending = false

    init(state: SpeechModelState) {
        self.state = state
    }

    var isIdle: Bool { running == nil && queue.isEmpty }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .download:
            return download()
        case .cancelDownload:
            return cancelDownload()
        case .replace:
            handoverPending = true
            switch state {
            case .downloaded, .loading, .ready:
                handoverPending = false
                return [.removeReplacedDirectory]
            case .notDownloaded, .failed:
                return download()
            case .downloading, .unsupported:
                return []
            }
        case .retry(let modelOnDisk):
            guard case .failed = state else { return [] }
            // Retry repeats what failed. A model that downloaded but failed to load is loaded again:
            // downloading it again would fetch it into staging and fail to move it onto the copy there.
            if failure == .removal { return remove() }
            return modelOnDisk ? startLoad() : download()
        case .loadIfDownloaded:
            guard state == .downloaded else { return [] }
            return startLoad()
        case .remove:
            return remove()
        case .progress(let fraction, let jobGeneration):
            guard jobGeneration == generation, case .downloading(let current) = state else { return [] }
            state = .downloading(max(current, min(max(fraction, 0), 1)))
            return []
        case .finished(let job, let outcome):
            return finished(job, outcome)
        case .settled(let modelOnDisk):
            // A result that arrived stale can leave the state behind the disk: a download that landed
            // as it was cancelled, or a Delete that failed after a later click. Once nothing is left
            // to run, the disk decides between the two states it can tell apart.
            guard isIdle else { return [] }
            if state == .notDownloaded, modelOnDisk {
                state = .downloaded
            } else if state == .downloaded, modelOnDisk == false {
                state = .notDownloaded
            }
            return []
        }
    }

    private mutating func download() -> [Effect] {
        switch state {
        case .notDownloaded, .failed:
            break
        case .unsupported, .downloading, .downloaded, .loading, .ready:
            return []
        }
        generation += 1
        state = .downloading(0)
        return enqueue(Job(operation: .download, generation: generation))
    }

    /// Stops a download in progress. A handover it was making ends too.
    private mutating func cancelDownload() -> [Effect] {
        guard case .downloading = state else { return [] }
        generation += 1
        state = .notDownloaded
        var effects: [Effect] = running?.operation == .download ? [.cancelRunningDownload] : []
        effects += endHandover()
        return effects
    }

    private mutating func startLoad() -> [Effect] {
        generation += 1
        state = .loading
        return enqueue(Job(operation: .load, generation: generation))
    }

    /// Shows "Not downloaded" at once, so nothing can start loading the model meanwhile, and queues a
    /// removal that runs after the work ahead of it.
    private mutating func remove() -> [Effect] {
        var effects: [Effect] = []
        if case .downloading = state { effects += cancelDownload() }
        generation += 1
        if state != .unsupported { state = .notDownloaded }
        effects += endHandover()
        effects += enqueue(Job(operation: .removal, generation: generation))
        return effects
    }

    private mutating func finished(_ job: Job, _ outcome: Outcome) -> [Effect] {
        guard running == job else { return [] }
        running = nil
        let isCurrent = job.generation == generation
        var effects: [Effect] = []
        switch (job.operation, outcome) {
        case (.download, .succeeded) where isCurrent:
            // The model is in place: the handover is done, and the model loads before anything else.
            effects += endHandover()
            state = .loading
            let load = Job(operation: .load, generation: job.generation)
            running = load
            return effects + [.start(load)]
        case (.download, .failed) where isCurrent:
            fail(.download, Self.downloadFailed)
        case (.load, .succeeded) where isCurrent:
            state = .ready
        case (.load, .failed) where isCurrent:
            fail(.load, Self.loadFailed)
        case (.removal, .succeeded) where isCurrent && state != .unsupported:
            state = .notDownloaded
        case (.removal, .failed) where isCurrent && state != .unsupported:
            fail(.removal, Self.removalFailed)
        default:
            break
        }
        effects += startNext()
        return isIdle ? effects + [.checkDisk] : effects
    }

    private mutating func enqueue(_ job: Job) -> [Effect] {
        guard running == nil else {
            queue.append(job)
            return []
        }
        running = job
        return [.start(job)]
    }

    /// Starts the next job that should still run.
    private mutating func startNext() -> [Effect] {
        while running == nil, queue.isEmpty == false {
            let job = queue.removeFirst()
            guard job.operation == .removal || job.generation == generation else { continue }
            running = job
            return [.start(job)]
        }
        return []
    }

    private mutating func endHandover() -> [Effect] {
        guard handoverPending else { return [] }
        handoverPending = false
        return [.removeReplacedDirectory]
    }

    private mutating func fail(_ kind: Failure, _ message: String) {
        failure = kind
        state = .failed(message)
    }
}
