import Foundation
import Synchronization
import Testing
@testable import Syrup

/// Replays every transition the explorer takes (the shortest trace to a state, then one more step) on
/// the real `SpeechModelManager`, with a real folder, and checks after every step that the manager's
/// state, the model on disk, and the older folder being replaced match what the machine predicts.
/// States with a queue longer than one are reached but not expanded: the manager runs queued jobs
/// the same way whatever the queue's length, and `SpeechModelExplorerTests` covers the machine's
/// queue to three. A model on disk while replacing explores the same states as one without, since
/// the older folder goes at once, so it is not replayed twice. Each fake operation waits for
/// the test's command, so a step happens exactly where the trace puts it; a removal is made to fail
/// with real file permissions.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SpeechModelConformanceTests {
    @Test(arguments: [(false, false), (false, true), (true, false)])
    func theManagerFollowsTheMachineOnEveryExploredTransition(modelOnDisk: Bool, replacing: Bool) async throws {
        var replayed = 0
        let start = SpeechModelExplorerTests.start(modelOnDisk: modelOnDisk, replacing: replacing)
        // Progress reports are checked by the explorer alone: the fakes report none.
        for trace in SpeechModelExplorerTests.explore(from: [start], maxQueue: 1).traces where trace.steps.contains(.report) == false {
            if let mismatch = try await Self.replay(trace.steps, from: start, modelOnDisk: modelOnDisk, replacing: replacing) {
                Issue.record("\(trace.origin), then \(trace.steps.map(\.rawValue).joined(separator: ", ")): \(mismatch)")
                return
            }
            replayed += 1
        }
        print("SpeechModelConformance: \(replayed) transitions from \(start.origin)")
        #expect(replayed > 100)
    }

    /// Returns the first difference between the manager and the machine, if any.
    static func replay(
        _ steps: [SpeechModelExplorerTests.Step], from start: SpeechModelExplorerTests.Node,
        modelOnDisk: Bool, replacing: Bool
    ) async throws -> String? {
        let fixture = try ConformanceFixture(modelOnDisk: modelOnDisk, replacing: replacing)
        let mismatch = await replay(steps, from: start, on: fixture)
        await fixture.close()
        return mismatch
    }

    private static func replay(
        _ steps: [SpeechModelExplorerTests.Step], from start: SpeechModelExplorerTests.Node, on fixture: ConformanceFixture
    ) async -> String? {
        var machine = start.machine
        var world = start.world
        guard await fixture.settle(waits: world.waits, idle: machine.isIdle) else {
            return "at the start: the fakes waited \(fixture.script.waits) times, expected \(world.waits)"
        }
        if let mismatch = fixture.mismatch(machine, world) { return "at the start: \(mismatch)" }

        for (index, step) in steps.enumerated() {
            _ = SpeechModelExplorerTests.perform(step, &machine, &world)
            switch step {
            case .download: fixture.manager.download()
            case .cancel: fixture.manager.cancelDownload()
            case .delete: fixture.manager.remove()
            case .load: fixture.manager.loadIfDownloaded()
            case .retry: fixture.manager.retry()
            case .begin, .land, .succeed, .fail, .failKeepingModel, .failRemovingModel: fixture.script.send(step)
            case .report: return "progress steps are not replayed"
            }
            guard await fixture.settle(waits: world.waits, idle: machine.isIdle) else {
                return "after step \(index + 1): the fakes waited \(fixture.script.waits) times, expected \(world.waits)"
            }
            fixture.restorePermissions()
            if let mismatch = fixture.mismatch(machine, world) { return "after step \(index + 1): \(mismatch)" }
        }
        return nil
    }
}

/// Each job's start and each operation call wait here for the test's command, ignoring cancellation
/// like a real job whose work is already under way. Once closed, every wait returns nil at once, so
/// the manager can finish what is left.
final class OperationScript: Sendable {
    private struct State {
        var waits = 0
        var closed = false
        /// Two operations waited at the same time, which one job at a time never allows.
        var overlapped = false
        var waiter: CheckedContinuation<SpeechModelExplorerTests.Step?, Never>?
    }

    private let state = Mutex(State())
    var waits: Int { state.withLock { $0.waits } }
    var overlapped: Bool { state.withLock { $0.overlapped } }

    func next() async -> SpeechModelExplorerTests.Step? {
        await withCheckedContinuation { continuation in
            let (resumeNow, earlier) = state.withLock { state -> (Bool, CheckedContinuation<SpeechModelExplorerTests.Step?, Never>?) in
                state.waits += 1
                if state.closed { return (true, nil) }
                let earlier = state.waiter
                if earlier != nil { state.overlapped = true }
                state.waiter = continuation
                return (false, earlier)
            }
            // The earlier operation is let go rather than left waiting forever; the overlap is reported.
            earlier?.resume(returning: nil)
            if resumeNow { continuation.resume(returning: nil) }
        }
    }

    func send(_ step: SpeechModelExplorerTests.Step?) {
        let waiter = state.withLock { state in
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: step)
    }

    func close() {
        state.withLock { $0.closed = true }
        send(nil)
    }
}

@MainActor
final class ConformanceFixture {
    let root: URL
    let older: URL
    let manager: SpeechModelManager
    let script: OperationScript
    private let directory: URL
    private let staging: URL

    init(modelOnDisk: Bool, replacing: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: testDomainName("SpeechModelConformance"), directoryHint: .isDirectory)
        let directory = root.appending(path: SpeechEngine.parakeetUltra.modelFolder ?? "model", directoryHint: .isDirectory)
        let staging = SpeechModelManager.stagingDirectory(for: directory)
        let older = root.appending(path: SpeechEngine.retiredParakeetV3Folder, directoryHint: .isDirectory)
        self.root = root
        self.older = older
        self.directory = directory
        self.staging = staging
        if modelOnDisk { try RegressionFixture.writeModel(at: directory) }
        if replacing { try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true) }
        let script = OperationScript()
        self.script = script
        manager = SpeechModelManager(
            engine: .parakeetUltra,
            operations: .init(
                modelsExist: { RegressionFixture.isComplete($0) },
                download: { directory, _ in
                    guard await script.next() == .land else { throw CocoaError(.fileWriteUnknown) }
                    try RegressionFixture.writeModel(at: directory)
                    guard await script.next() == .succeed else { throw CocoaError(.fileWriteUnknown) }
                },
                load: { directory in
                    guard await script.next() == .succeed, RegressionFixture.isComplete(directory) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                },
                unload: {
                    guard let step = await script.next(), step != .succeed else { return }
                    Self.makeRemovalFail(keepingModel: step == .failKeepingModel, root: root, directory: directory, staging: staging)
                },
                willBeginJob: {
                    _ = await script.next()
                }
            ),
            isSupported: true,
            storageDirectory: root
        )
        if replacing { manager.replace(older) }
    }

    /// Waits until the job the machine expects has reached its next wait, or the manager is idle.
    /// False if the fakes never reach the expected count, so the replay stops at the first difference
    /// instead of waiting out a timeout at every later step.
    func settle(waits: Int, idle: Bool) async -> Bool {
        let script = script
        let reached = await eventually(timeout: .seconds(2)) { script.waits == waits || script.overlapped }
        guard reached, script.overlapped == false else { return false }
        guard idle else { return true }
        // Bounded: a manager that started work the machine did not would otherwise hold this forever.
        let drained = IdleFlag()
        let waiter = Task { await manager.waitUntilIdle(); drained.value = true }
        guard await eventually(timeout: .seconds(2), { drained.value }) else {
            waiter.cancel()
            return false
        }
        return script.waits == waits
    }

    func mismatch(_ machine: SpeechModelMachine, _ world: SpeechModelExplorerTests.World) -> String? {
        var problems: [String] = []
        if script.overlapped { problems.append("two operations ran at once") }
        if manager.state != machine.state { problems.append("manager is \(manager.state), machine is \(machine.state)") }
        if RegressionFixture.isComplete(directory) != world.modelOnDisk { problems.append("model on disk is \(RegressionFixture.isComplete(directory)), expected \(world.modelOnDisk)") }
        let olderExists = FileManager.default.fileExists(atPath: older.path(percentEncoded: false))
        if olderExists != world.replacedOnDisk { problems.append("older folder exists is \(olderExists), expected \(world.replacedOnDisk)") }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    /// A removal that keeps the model: the model folder cannot be emptied. One that removes the
    /// model's files but fails: its parent cannot lose the folder. With no model, an undeletable
    /// staging folder makes either fail.
    nonisolated static func makeRemovalFail(keepingModel: Bool, root: URL, directory: URL, staging: URL) {
        let fileManager = FileManager.default
        if RegressionFixture.isComplete(directory) {
            let locked = keepingModel ? directory : root
            try? fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path(percentEncoded: false))
        } else {
            try? fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            try? Data("partial".utf8).write(to: staging.appending(path: "part"))
            try? fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: staging.path(percentEncoded: false))
        }
    }

    func restorePermissions() {
        for folder in [root, directory, staging] where FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path(percentEncoded: false))
        }
    }

    /// Lets every held operation go, waits for the manager to finish what is left, then removes the
    /// folder, so no manager or task outlives its trace.
    func close() async {
        script.close()
        await manager.waitUntilIdle()
        restorePermissions()
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class IdleFlag {
    var value = false
}
