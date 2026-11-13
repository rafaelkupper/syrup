import Foundation

enum ReleaseTail {
    private static let nearSilence = -50.0
    private static let roomNoiseHeadroom = 5.0
    static let quietLevel = nearSilence + roomNoiseHeadroom
    static let deadline: Duration = .milliseconds(200)

    enum Event: Sendable {
        case bufferLevel(dBFS: Double)
        case deadlineReached
    }

    enum Decision: Equatable, Sendable {
        case `continue`
        case finish
    }

    static func decision(after event: Event) -> Decision {
        switch event {
        case .bufferLevel(let dBFS):
            dBFS < quietLevel ? .finish : .continue
        case .deadlineReached:
            .finish
        }
    }
}
