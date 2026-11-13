import Foundation

@inline(never)
func route(_ list: WorkflowList, _ app: String?) -> UUID? {
    list.routedWorkflowID(for: app)
}

let iterations = 1_000_000
let rounds = 11
let workflow = Workflow(id: UUID(), name: "Benchmark", kind: .transcribeOnly(cleanup: false),
                        dictationLocaleID: "en-US", translationProvider: nil)
let empty = WorkflowList(workflows: [workflow])
let routed = WorkflowList(workflows: [workflow], appRouting: ["benchmark.app": workflow.id])
let inputs = ["benchmark.app", "missing.app", "benchmark.app", "other.app"]
var consumed = 0
let clock = ContinuousClock()
print("round\tmode\tnanoseconds_per_lookup\thits\tlookups")
for round in 0..<rounds {
    let modes = round.isMultiple(of: 2) ? ["empty", "configured"] : ["configured", "empty"]
    for mode in modes {
        let list = mode == "empty" ? empty : routed
        var hits = 0
        let start = clock.now
        for index in 0..<iterations {
            if route(list, inputs[index & 3]) == workflow.id { hits += 1 }
        }
        let duration = start.duration(to: clock.now).components
        let nanos = Double(duration.seconds) * 1_000_000_000 + Double(duration.attoseconds) / 1_000_000_000
        precondition(hits == (mode == "empty" ? 0 : iterations / 2))
        consumed += hits
        print("\(round)\t\(mode)\t\(nanos / Double(iterations))\t\(hits)\t\(iterations)")
    }
}
precondition(consumed == rounds * iterations / 2)
