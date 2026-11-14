import Testing
@testable import Syrup

/// Runs every interleaving of clicks and completions against `SpeechModelMachine`, breadth first, so
/// each problem is reported with the shortest sequence that reaches it. A started job begins in a
/// step of its own, so clicks can come between a job being queued and its task running. The disk is
/// simulated: a download can move the model into place and then return, or fail before; a load fails or, with the
/// model on disk, succeeds; a removal succeeds, fails leaving the model, or fails after deleting the
/// model's files but not its folder. A cancelled download can still land, as a real one can once its
/// files have started moving. Generations are compared only as "current" or "stale", which is all
/// the machine compares, so the reachable states are finite; queues longer than three are not
/// expanded.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SpeechModelExplorerTests {
    enum Step: String, Hashable, Sendable {
        case download, cancel, delete, load, retry
        /// `report`: the running download reports progress, which the conformance test does not replay.
        case begin, report, land, succeed, fail, failKeepingModel, failRemovingModel
    }

    struct World: Equatable {
        var modelOnDisk: Bool
        var replacedOnDisk = false
        /// The job the simulated disk is running, which must be the machine's `running` job.
        var executing: SpeechModelMachine.Job?
        /// Whether the executing job's task has begun and the machine let it run.
        var performing = false
        var landed = false
        /// A Delete was accepted and its removal has not started yet.
        var deletePending = false
        /// How many times the real fakes would have waited for a command so far: once as each job
        /// begins, once as its work starts, and once after a download lands. Not part of the state.
        var waits = 0
    }

    struct Node {
        var machine: SpeechModelMachine
        var world: World
        var trace: [Step]
        /// Where the trace starts, for the report.
        var origin: String
    }

    struct Exploration {
        var states = 0
        var violations: [String] = []
        /// For every transition explored: the shortest trace to its state, then its step.
        var traces: [(origin: String, steps: [Step])] = []
    }

    @Test(arguments: [false, true])
    func everyInterleavingKeepsTheInvariants(modelOnDisk: Bool) {
        var starts = [Self.start(modelOnDisk: modelOnDisk, replacing: false)]
        starts.append(Self.start(modelOnDisk: modelOnDisk, replacing: true))
        let result = Self.explore(from: starts)
        print("SpeechModelExplorer: \(result.states) states and \(result.traces.count) transitions from \(modelOnDisk ? "a model on disk" : "no model")")
        #expect(result.violations.isEmpty, "\(result.violations.count) violations, first: \(result.violations.prefix(5).joined(separator: "\n"))")
        #expect(result.states > 100, "Explored only \(result.states) states")
    }

    @Test func anUnsupportedModelStaysUnsupported() {
        var machine = SpeechModelMachine(state: .unsupported)
        var world = World(modelOnDisk: false)
        _ = Self.apply(&machine, &world, effects: [])
        let result = Self.explore(from: [Node(machine: machine, world: world, trace: [], origin: "unsupported")])
        #expect(result.violations.isEmpty, "\(result.violations.prefix(5).joined(separator: "\n"))")
    }

    // MARK: - Exploration

    static func start(modelOnDisk: Bool, replacing: Bool) -> Node {
        var machine = SpeechModelMachine(state: modelOnDisk ? .downloaded : .notDownloaded)
        var world = World(modelOnDisk: modelOnDisk, replacedOnDisk: replacing)
        if replacing {
            let effects = machine.handle(.replace)
            _ = apply(&machine, &world, effects: effects)
        }
        let origin = (modelOnDisk ? "model on disk" : "no model") + (replacing ? ", replacing an older folder" : "")
        return Node(machine: machine, world: world, trace: [], origin: origin)
    }

    /// Nodes whose queue is longer than `maxQueue` are recorded but not expanded.
    static func explore(from starts: [Node], maxQueue: Int = 3) -> Exploration {
        var result = Exploration()
        var seen: Set<String> = []
        var frontier = starts.filter { seen.insert(key($0)).inserted }
        let unsupported = starts.allSatisfy { $0.machine.state == .unsupported }
        while frontier.isEmpty == false {
            var next: [Node] = []
            for node in frontier {
                result.states += 1
                guard node.machine.queue.count <= maxQueue else { continue }
                for step in enabledSteps(node) {
                    var machine = node.machine
                    var world = node.world
                    let trace = node.trace + [step]
                    result.traces.append((node.origin, trace))
                    var problems = perform(step, &machine, &world)
                    problems += invariantViolations(machine, world)
                    if unsupported, machine.state != .unsupported { problems.append("an unsupported model became \(machine.state)") }
                    if problems.isEmpty == false {
                        result.violations.append("\(node.origin), then \(trace.map(\.rawValue).joined(separator: ", ")): \(problems.joined(separator: "; "))")
                        continue
                    }
                    let child = Node(machine: machine, world: world, trace: trace, origin: node.origin)
                    if seen.insert(key(child)).inserted { next.append(child) }
                }
            }
            frontier = next
        }
        return result
    }

    static func enabledSteps(_ node: Node) -> [Step] {
        var steps: [Step] = [.download, .cancel, .delete, .load, .retry]
        if let job = node.world.executing {
            guard node.world.performing else { return steps + [.begin] }
            switch job.operation {
            case .download: steps += node.world.landed ? [.succeed] : [.report, .land, .fail]
            case .load: steps += node.world.modelOnDisk ? [.succeed, .fail] : [.fail]
            case .removal: steps += [.succeed, .failKeepingModel, .failRemovingModel]
            }
        }
        return steps
    }

    /// Applies a step and returns any problem it shows directly.
    static func perform(_ step: Step, _ machine: inout SpeechModelMachine, _ world: inout World) -> [String] {
        var problems: [String] = []
        let before = machine
        let effects: [SpeechModelMachine.Effect]
        switch step {
        case .download: effects = machine.handle(.download)
        case .cancel: effects = machine.handle(.cancelDownload)
        case .delete: effects = machine.handle(.remove)
        case .load: effects = machine.handle(.loadIfDownloaded)
        case .retry: effects = machine.handle(.retry(modelOnDisk: world.modelOnDisk))
        case .begin:
            guard let job = world.executing, world.performing == false else { return ["nothing to begin"] }
            effects = machine.handle(.began(job))
            if effects.contains(.perform(job)) == false { world.executing = nil }
        case .report:
            guard let job = world.executing, job.operation == .download else { return ["no download to report"] }
            effects = machine.handle(.progress(0.5, generation: job.generation))
            if job.generation != before.generation, machine.state != before.state {
                problems.append("progress from a stale download changed \(before.state) to \(machine.state)")
            }
            if case .downloading(let old) = before.state, case .downloading(let new) = machine.state, new < old {
                problems.append("progress went back from \(old) to \(new)")
            }
        case .land:
            world.modelOnDisk = true
            world.landed = true
            world.waits += 1
            effects = []
        case .succeed, .fail, .failKeepingModel, .failRemovingModel:
            guard let job = world.executing else { return ["no job to finish"] }
            if job.operation == .removal, step == .succeed || step == .failRemovingModel { world.modelOnDisk = false }
            world.executing = nil
            world.performing = false
            effects = machine.handle(.finished(job, step == .succeed ? .succeeded : .failed))
        }
        // A removal accepted by this step carries a generation newer than any before it.
        if ([machine.running].compactMap { $0 } + machine.queue).contains(where: { $0.operation == .removal && $0.generation > before.generation }) {
            world.deletePending = true
        }
        problems += apply(&machine, &world, effects: effects)
        if step == .retry, case .failed = before.state, before.failure == .removal {
            let started = [machine.running].compactMap { $0 } + machine.queue
            if started.contains(where: { $0.generation == machine.generation && $0.operation != .removal }) {
                problems.append("Retry after a failed removal started a \(started.last.map { "\($0.operation)" } ?? "job")")
            }
            if started.contains(where: { $0.generation == machine.generation && $0.operation == .removal }) == false {
                problems.append("Retry after a failed removal did not remove again")
            }
        }
        return problems
    }

    /// Runs effects against the simulated disk, feeding disk checks back into the machine.
    static func apply(_ machine: inout SpeechModelMachine, _ world: inout World, effects: [SpeechModelMachine.Effect]) -> [String] {
        var problems: [String] = []
        var pending = effects
        while pending.isEmpty == false {
            switch pending.removeFirst() {
            case .start(let job):
                if let executing = world.executing { problems.append("started \(job.operation) while \(executing.operation) was running") }
                world.executing = job
                world.performing = false
                world.landed = false
                world.waits += 1
            case .perform(let job):
                if world.executing != job || world.performing { problems.append("performed \(job.operation) that had not begun") }
                if job.operation != .removal, job.generation != machine.generation { problems.append("performed a stale \(job.operation)") }
                if job.operation == .download, world.deletePending { problems.append("a download started before an accepted Delete ran") }
                if job.operation == .removal { world.deletePending = false }
                world.performing = true
                world.waits += 1
            case .cancelRunningDownload:
                if world.executing?.operation != .download { problems.append("cancelled a download that was not running") }
            case .removeReplacedDirectory:
                world.replacedOnDisk = false
            case .checkDisk:
                pending += machine.handle(.settled(modelOnDisk: world.modelOnDisk))
            }
        }
        return problems
    }

    static func invariantViolations(_ machine: SpeechModelMachine, _ world: World) -> [String] {
        var problems: [String] = []
        if machine.running != world.executing { problems.append("machine runs \(String(describing: machine.running)) but the disk runs \(String(describing: world.executing))") }
        // The older folder of a handover goes once the model is on disk, or on Cancel or Delete, and
        // stays while the handover is still under way or its download failed.
        if world.replacedOnDisk != machine.handoverPending {
            problems.append("older folder on disk is \(world.replacedOnDisk) while the handover pending is \(machine.handoverPending)")
        }
        guard machine.isIdle else { return problems }
        if world.deletePending { problems.append("idle with an accepted Delete that never ran") }
        switch machine.state {
        case .downloaded, .ready:
            if world.modelOnDisk == false { problems.append("idle and \(machine.state) without the model on disk") }
        case .notDownloaded:
            if world.modelOnDisk { problems.append("idle and not downloaded with the model on disk") }
        case .downloading, .loading:
            problems.append("idle and still \(machine.state)")
        case .failed, .unsupported:
            break
        }
        return problems
    }

    /// Everything the machine's behavior depends on, with generations reduced to current or stale.
    static func key(_ node: Node) -> String {
        let machine = node.machine
        func job(_ job: SpeechModelMachine.Job?) -> String {
            guard let job else { return "-" }
            return "\(job.operation)\(job.generation == machine.generation ? "" : "~")"
        }
        return [
            "\(machine.state)", "\(String(describing: machine.failure))", job(machine.running),
            machine.queue.map { job($0) }.joined(separator: ","), "\(machine.handoverPending)",
            "\(node.world.modelOnDisk)", "\(node.world.replacedOnDisk)", "\(node.world.performing)", "\(node.world.landed)", "\(node.world.deletePending)",
        ].joined(separator: "|")
    }
}
