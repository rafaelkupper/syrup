import AppKit

/// Selectable completion sound played when a run finishes successfully.
///
/// Each case maps to a macOS system sound in `/System/Library/Sounds`, loadable
/// via `NSSound(named:)` — no bundled audio assets. `chime` maps to the historical
/// "Glass" sound so existing installs keep the same feedback by default.
enum SuccessSound: String, CaseIterable, Identifiable, Sendable, Codable {
    case chime
    case click
    case boop
    case drop
    case swipe
    case ping
    case sonar

    var id: String { rawValue }

    /// Name of the macOS system sound backing this option.
    var systemSoundName: String {
        switch self {
        case .chime:
            "Glass"
        case .click:
            "Tink"
        case .boop:
            "Pop"
        case .drop:
            "Bottle"
        case .swipe:
            "Blow"
        case .ping:
            "Ping"
        case .sonar:
            "Submarine"
        }
    }

    var displayName: String {
        switch self {
        case .chime:
            "Chime"
        case .click:
            "Click"
        case .boop:
            "Boop"
        case .drop:
            "Water drop"
        case .swipe:
            "Swipe"
        case .ping:
            "Ping"
        case .sonar:
            "Sonar"
        }
    }

    static let `default` = SuccessSound.chime

    @MainActor
    func play() {
        NSSound(named: systemSoundName)?.play()
    }
}
