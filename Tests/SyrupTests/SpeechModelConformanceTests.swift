import Foundation
import Synchronization
import Testing
@testable import Syrup

/// Replays the explorer's shortest trace to every state it reached on the real `SpeechModelManager`,
/// with a real folder, and checks after every step that the manager's state, the model on disk, and
/// the older folder being replaced match what the machine predicts. Each fake operation waits for
/// the test's command, so a step happens exactly where the trace puts it; a removal is made to fail
/// with real file permissions.
@MainActor
struct SpeechModelConformanceTests {
    @Test(arguments: [false, true], [false, true])
    func theManagerFollowsTheMachineOnEveryExploredTransition(modelOnDisk: Bool, replacing: Bool) async throws {
        var replayed = 0
        let start = SpeechModelExplorerTests.start(modelOnDisk: modelOnDisk, replacing: replacing)
        for trace in SpeechModelExplorerTests.explore(from: [start]).traces {
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
        defer { fixture.clean() }
        var machine = start.machine
        var world = start.world
        var waits = world.executing == nil ? 0 : 1
        await fixture.settle(waits: waits, idle: machine.isIdle)
        if let mismatch = fixture.mismatch(machine, world) { return "at the start: \(mismatch)" }

        for (index, step) in steps.enumerated() {
            let before = world
            _ = SpeechModelExplorerTests.perform(step, &machine, &world)
            let finishes = [.succeed, .fail, .failKeepingModel, .failRemovingModel].contains(step)
            if step == .land { waits += 1 }
            if world.executing != nil, before.executing == nil || finishes { waits += 1 }

            switch step {
            case .download: fixture.manager.download()
            case .cancel: fixture.manager.cancelDownload()
            case .delete: fixture.manager.remove()
            case .load: fixture.manager.loadIfDownloaded()
            case .retry: fixture.manager.retry()
            case .land, .succeed, .fail, .failKeepingModel, .failRemovingModel: fixture.script.send(step)
            }
            await fixture.settle(waits: waits, idle: machine.isIdle)
            fixture.restorePermissions()
            if let mismatch = fixture.mismatch(machine, world) { return "after step \(index + 1): \(mismatch)" }
        }
        return nil
    }
}

/// Each operation call waits here for the test's command, ignoring cancellation like a real job
/// whose work is already under way.
final class OperationScript: Sendable {
    private struct State {
        var waits = 0
        var waiter: CheckedContinuation<SpeechModelExplorerTests.Step, Never>?
    }

    private let state = Mutex(State())
    var waits: Int { state.withLock { $0.waits } }

    func next() async -> SpeechModelExplorerTests.Step {
        await withCheckedContinuation { continuation in
            state.withLock {
                $0.waits += 1
                $0.waiter = continuation
            }
        }
    }

    func send(_ step: SpeechModelExplorerTests.Step) {
        let waiter = state.withLock { state in
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume(returning: step)
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
                    let step = await script.next()
                    guard step != .succeed else { return }
                    Self.makeRemovalFail(keepingModel: step == .failKeepingModel, root: root, directory: directory, staging: staging)
                }
            ),
            isSupported: true,
            storageDirectory: root
        )
        if replacing { manager.replace(older) }
    }

    /// Waits until the job the machine expects has reached its next wait, or the manager is idle.
    func settle(waits: Int, idle: Bool) async {
        await eventually("The fake operations waited \(script.waits) times, not \(waits)") { self.script.waits == waits }
        if idle { await manager.waitUntilIdle() }
    }

    func mismatch(_ machine: SpeechModelMachine, _ world: SpeechModelExplorerTests.World) -> String? {
        var problems: [String] = []
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

    func clean() {
        restorePermissions()
        try? FileManager.default.removeItem(at: root)
    }
}
