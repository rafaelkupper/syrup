import Testing
@testable import Syrup

/// The checker itself, on a door that can jam: the facts every model check relies on.
struct ModelCheckerTests {
    private struct Door: StateMachineModel {
        enum State: Hashable { case closed, open, locked, jammed }
        enum Action: String, Hashable, CustomStringConvertible {
            case open, close, lock, unlock, slam
            var description: String { rawValue }
        }

        var initialStates: [State] { [.closed] }

        func successors(of state: State) -> [(action: Action, next: State)] {
            switch state {
            case .closed: [(.open, .open), (.lock, .locked)]
            case .open: [(.close, .closed), (.slam, .jammed)]
            case .locked: [(.unlock, .closed)]
            case .jammed: []
            }
        }
    }

    @Test func exploresEveryReachableStateAndTransition() {
        let checker = ModelChecker(Door())
        #expect(checker.stateCount == 4)
        #expect(checker.transitionCount == 5)
    }

    @Test func findsTheShortestTraceToAViolation() {
        let checker = ModelChecker(Door())
        let found = checker.violations { $0 != .jammed }
        #expect(found.count == 1)
        #expect(found.first.map { checker.trace(to: $0) } == [.open, .slam])
    }

    @Test func findsStatesThatCanNeverReturn() {
        let checker = ModelChecker(Door())
        let stuck = checker.statesThatCannotReach { $0 == .closed }
        #expect(stuck.map { checker.states[$0] } == [.jammed])
    }

    @Test func checksWhatEachActionMayChange() {
        let checker = ModelChecker(Door())
        let lockedWhileOpen = checker.violations(ofStep: { from, action, _ in action != .lock || from == .closed })
        #expect(lockedWhileOpen.isEmpty)
        let slams = checker.violations(ofStep: { _, action, _ in action != .slam })
        #expect(slams.map { checker.trace(to: $0.source) + [$0.action] } == [[.open, .slam]])
    }

    @Test func aTourTakesEveryTransitionAndRestartsOnlyWhenStuck() {
        let checker = ModelChecker(Door())
        let walks = checker.tour(covering: .transitions)
        var taken = Set<String>()
        for walk in walks {
            var state = checker.states[walk.start]
            for step in walk.steps {
                #expect(checker.model.successors(of: state).contains { $0.action == step.action && $0.next == checker.states[step.target] })
                taken.insert("\(state) \(step.action)")
                state = checker.states[step.target]
            }
        }
        #expect(taken.count == checker.transitionCount)
        // Jamming is a dead end, so the one walk that suffices must save the slam for last.
        #expect(walks.count == 1)
        #expect(walks.first?.steps.last?.action == .slam)
        #expect(checker.tour(covering: .transitions).map(\.steps.count) == walks.map(\.steps.count), "The tour is deterministic")
    }

    @Test func aStateTourVisitsEveryState() {
        let checker = ModelChecker(Door())
        var visited: Set<Door.State> = []
        for walk in checker.tour(covering: .states) {
            visited.insert(checker.states[walk.start])
            for step in walk.steps { visited.insert(checker.states[step.target]) }
        }
        #expect(visited.count == checker.stateCount)
    }

    @Test func reportsABrokenPropertyWithItsTrace() {
        let checker = ModelChecker(Door())
        withKnownIssue {
            checker.expect("never jams", holdsIn: { $0 != .jammed })
        } matching: { issue in
            issue.comments.contains { $0.rawValue.contains("open -> slam") }
        }
        withKnownIssue {
            checker.expect("can always close", canAlwaysReach: { $0 == .closed })
        }
        #expect(checker.expect("never locked open", holdsOnEveryStep: { from, action, _ in action != .lock || from == .closed }))
    }
}
