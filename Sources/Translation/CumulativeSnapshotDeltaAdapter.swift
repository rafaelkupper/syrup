enum CumulativeSnapshotDelta: Equatable, Sendable {
    case delta(String)
    case requiresAtomicFallback
}

struct CumulativeSnapshotDeltaAdapter: Sendable {
    private var previousSnapshot = ""

    mutating func append(_ snapshot: String) -> CumulativeSnapshotDelta {
        guard snapshot.hasPrefix(previousSnapshot) else {
            return .requiresAtomicFallback
        }

        let delta = String(snapshot.dropFirst(previousSnapshot.count))
        previousSnapshot = snapshot
        return .delta(delta)
    }
}
