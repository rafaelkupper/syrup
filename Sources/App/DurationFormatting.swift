import Foundation

extension Duration {
    var millisecondsDescription: String {
        let components = components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return String(format: "%.3f", milliseconds)
    }
}
