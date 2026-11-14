import Foundation
import Testing

/// A finite model of one of Syrup's state machines: its initial states, and for any state every
/// action that can happen next with the state it leads to. Actions include user input, callbacks,
/// async completions, timers, and cancellation, so exploring all of them explores every interleaving.
protocol StateMachineModel {
    associatedtype State: Hashable
    associatedtype Action: Hashable & CustomStringConvertible

    var initialStates: [State] { get }
    func successors(of state: State) -> [(action: Action, next: State)]
}

/// Explicit-state model checking, the technique TLC uses: a breadth-first walk of every state a
/// finite model can reach, keeping for each state the action that first reached it, so any finding
/// comes with the shortest trace that produces it.
struct ModelChecker<Model: StateMachineModel> {
    typealias State = Model.State
    typealias Action = Model.Action

    struct Edge {
        let action: Action
        let target: Int
    }

    let model: Model
    private(set) var states: [State] = []
    private(set) var edges: [[Edge]] = []
    /// For every state but the initial ones, the state and action that first reached it.
    private var parents: [Int: (state: Int, action: Action)] = [:]
    private var index: [State: Int] = [:]

    /// Explores the whole reachable state space. Fails the test, rather than hanging, when the model
    /// is larger than `limit`, because that means its abstraction is not finite.
    init(_ model: Model, limit: Int = 200_000, sourceLocation: SourceLocation = #_sourceLocation) {
        self.model = model
        var queue: [Int] = []
        for state in model.initialStates where index[state] == nil {
            queue.append(add(state))
        }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for (action, next) in model.successors(of: states[current]) {
                let target: Int
                if let known = index[next] {
                    target = known
                } else {
                    guard states.count < limit else {
                        Issue.record("The model has more than \(limit) states; its abstraction is not finite", sourceLocation: sourceLocation)
                        return
                    }
                    target = add(next)
                    parents[target] = (current, action)
                    queue.append(target)
                }
                edges[current].append(Edge(action: action, target: target))
            }
        }
    }

    private mutating func add(_ state: State) -> Int {
        let id = states.count
        states.append(state)
        edges.append([])
        index[state] = id
        return id
    }

    var stateCount: Int { states.count }
    var transitionCount: Int { edges.reduce(0) { $0 + $1.count } }

    /// The shortest sequence of actions from an initial state to `state`.
    func trace(to state: Int) -> [Action] {
        var actions: [Action] = []
        var current = state
        while let parent = parents[current] {
            actions.append(parent.action)
            current = parent.state
        }
        return actions.reversed()
    }

    func describeTrace(to state: Int) -> String {
        let steps = trace(to: state).map(\.description)
        return (steps.isEmpty ? "the initial state" : steps.joined(separator: " -> ")) + "\n  reaches \(states[state])"
    }

    /// Every reachable state where `invariant` is false, nearest first.
    func violations(of invariant: (State) -> Bool) -> [Int] {
        states.indices.filter { invariant(states[$0]) == false }
    }

    /// Every transition that breaks `property`, which sees the state before, the action, and the
    /// state after. For rules about what an action may change, such as "a cancelled run never
    /// writes the clipboard".
    func violations(ofStep property: (State, Action, State) -> Bool) -> [(source: Int, action: Action, target: Int)] {
        var found: [(Int, Action, Int)] = []
        for source in states.indices {
            for edge in edges[source] where property(states[source], edge.action, states[edge.target]) == false {
                found.append((source, edge.action, edge.target))
            }
        }
        return found
    }

    /// Reachable states from which no sequence of actions reaches a state where `goal` holds: the
    /// machine can get stuck there. This is the CTL property AG EF goal, checked by walking the
    /// transitions backwards from every goal state.
    /// `using` limits the walk to some actions, such as only timers and completions, to ask whether
    /// the machine gets there without the person doing anything more.
    func statesThatCannotReach(_ goal: (State) -> Bool, using allowed: (Action) -> Bool = { _ in true }) -> [Int] {
        var reverse = Array(repeating: [Int](), count: states.count)
        for source in states.indices {
            for edge in edges[source] where allowed(edge.action) { reverse[edge.target].append(source) }
        }
        var canReach = Array(repeating: false, count: states.count)
        var queue = states.indices.filter { goal(states[$0]) }
        for state in queue { canReach[state] = true }
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            for source in reverse[current] where canReach[source] == false {
                canReach[source] = true
                queue.append(source)
            }
        }
        return states.indices.filter { canReach[$0] == false }
    }

    enum TourCoverage {
        /// Every reachable state at least once: cheap enough for every test run.
        case states
        /// Every transition at least once: the full check, a few times longer.
        case transitions
    }

    /// Walks that together cover every state or every transition, for replaying the model against
    /// the real code. From where it is, a walk goes to the nearest state that still has work: a
    /// transition not yet taken, or for state coverage a transition into a state not yet visited.
    /// When none is reachable, a new walk starts from an initial state. Each walk is its initial
    /// state and its steps, with the state every step reaches.
    func tour(covering coverage: TourCoverage) -> [(start: Int, steps: [(action: Action, target: Int)])] {
        switch coverage {
        case .transitions: transitionTour()
        case .states: stateTour()
        }
    }

    private func stateTour() -> [(start: Int, steps: [(action: Action, target: Int)])] {
        var visited = Array(repeating: false, count: states.count)
        var remaining = states.count
        var walks: [(start: Int, steps: [(action: Action, target: Int)])] = []
        let initials = model.initialStates.compactMap { index[$0] }

        func visit(_ state: Int) {
            if visited[state] == false {
                visited[state] = true
                remaining -= 1
            }
        }

        /// The shortest path from `origin` to a state not yet visited, as edges.
        func pathToUnvisited(from origin: Int) -> [(source: Int, edge: Int)]? {
            var previous: [Int: (source: Int, edge: Int)] = [:]
            var seen: Set<Int> = [origin]
            var queue = [origin]
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                if visited[current] == false {
                    var path: [(Int, Int)] = []
                    var node = current
                    while node != origin, let step = previous[node] {
                        path.append(step)
                        node = step.source
                    }
                    return path.reversed()
                }
                for (number, edge) in edges[current].enumerated() where seen.insert(edge.target).inserted {
                    previous[edge.target] = (current, number)
                    queue.append(edge.target)
                }
            }
            return nil
        }

        while remaining > 0 {
            guard let start = initials.first(where: { visited[$0] == false || pathToUnvisited(from: $0) != nil }) else { break }
            visit(start)
            var steps: [(action: Action, target: Int)] = []
            var current = start
            while let path = pathToUnvisited(from: current), path.isEmpty == false {
                for (source, number) in path {
                    let edge = edges[source][number]
                    steps.append((edge.action, edge.target))
                    visit(edge.target)
                    current = edge.target
                }
            }
            walks.append((start, steps))
        }
        return walks
    }

    private func transitionTour() -> [(start: Int, steps: [(action: Action, target: Int)])] {
        // Arrays, not sets, so the tour is the same on every run and a failure can be replayed.
        var taken = edges.map { Array(repeating: false, count: $0.count) }
        var untakenCount = edges.map(\.count)
        var remaining = transitionCount
        var walks: [(start: Int, steps: [(action: Action, target: Int)])] = []
        let initials = model.initialStates.compactMap { index[$0] }

        func take(_ source: Int, _ number: Int) {
            guard taken[source][number] == false else { return }
            taken[source][number] = true
            untakenCount[source] -= 1
            remaining -= 1
        }

        /// The shortest path from `origin` to a state with an untaken transition, as edges.
        func pathToWork(from origin: Int) -> [(source: Int, edge: Int)]? {
            var previous: [Int: (source: Int, edge: Int)] = [:]
            var seen: Set<Int> = [origin]
            var queue = [origin]
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                if untakenCount[current] > 0 {
                    var path: [(Int, Int)] = []
                    var node = current
                    while node != origin, let step = previous[node] {
                        path.append(step)
                        node = step.source
                    }
                    return path.reversed()
                }
                for (number, edge) in edges[current].enumerated() where seen.insert(edge.target).inserted {
                    previous[edge.target] = (current, number)
                    queue.append(edge.target)
                }
            }
            return nil
        }

        while remaining > 0 {
            guard let start = initials.first(where: { pathToWork(from: $0) != nil }) else { break }
            var steps: [(action: Action, target: Int)] = []
            var current = start
            while let path = pathToWork(from: current) {
                for (source, number) in path {
                    take(source, number)
                    let edge = edges[source][number]
                    steps.append((edge.action, edge.target))
                    current = edge.target
                }
                guard let number = taken[current].firstIndex(of: false) else { break }
                take(current, number)
                let edge = edges[current][number]
                steps.append((edge.action, edge.target))
                current = edge.target
            }
            walks.append((start, steps))
        }
        return walks
    }

    /// Records one issue per broken property, with the shortest counterexample, and returns whether
    /// the model satisfied it. Only the first few counterexamples are shown.
    @discardableResult
    func expect(
        _ name: String, holdsIn invariant: (State) -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        report(name, violations(of: invariant), sourceLocation: sourceLocation)
    }

    @discardableResult
    func expect(
        _ name: String, holdsOnEveryStep property: (State, Action, State) -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        let found = violations(ofStep: property)
        guard let first = found.first else { return true }
        Issue.record(Comment(rawValue: """
            \(name): broken by \(found.count) transition(s). Shortest:
              \(describeTrace(to: first.source)) -> \(first.action)
              reaches \(states[first.target])
            """), sourceLocation: sourceLocation)
        return false
    }

    @discardableResult
    func expect(
        _ name: String, canAlwaysReach goal: (State) -> Bool, using allowed: (Action) -> Bool = { _ in true },
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        report("\(name) (stuck states)", statesThatCannotReach(goal, using: allowed), sourceLocation: sourceLocation)
    }

    private func report(_ name: String, _ found: [Int], sourceLocation: SourceLocation) -> Bool {
        guard found.isEmpty == false else { return true }
        let shown = found.prefix(3).map { "  " + describeTrace(to: $0) }.joined(separator: "\n")
        Issue.record(Comment(rawValue: "\(name): \(found.count) reachable state(s) break it. Shortest:\n\(shown)"),
                     sourceLocation: sourceLocation)
        return false
    }
}
