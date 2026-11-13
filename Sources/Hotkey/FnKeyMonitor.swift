import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct FnKeySample: Equatable {
    var isFnDown: Bool
    var hasOtherModifiers: Bool
    var secondsSinceKeyDown: TimeInterval
    var time: TimeInterval
}

enum FnKeyEvent: Equatable {
    case pressed
    case released(heldFor: TimeInterval, completesDoubleTap: Bool = false)
    /// Fn was used with another key, like Fn+Delete, so it was not meant for Syrup.
    case combined
}

/// Fn alone is a gesture. Fn with anything else belongs to macOS or the app in front.
struct FnKeyGesture {
    /// Longest press that counts as a tap. It matches the shortest hold `AppState` keeps as a dictation.
    static let maximumTap: TimeInterval = 0.3
    /// Longest gap from releasing the first tap to pressing the second.
    static let doubleTapWindow: TimeInterval = 0.35

    private enum Phase {
        case up
        case active(pressedAt: TimeInterval, followsTap: Bool)
        case ignoring
    }

    private var phase = Phase.up
    private var lastTapEndedAt: TimeInterval?

    mutating func advance(_ sample: FnKeySample) -> FnKeyEvent? {
        switch phase {
        case .up:
            guard sample.isFnDown else { return nil }
            let followsTap = lastTapEndedAt.map { sample.time - $0 <= Self.doubleTapWindow } ?? false
            lastTapEndedAt = nil
            guard sample.hasOtherModifiers == false else {
                phase = .ignoring
                return nil
            }
            phase = .active(pressedAt: sample.time, followsTap: followsTap)
            return .pressed
        case .active(let pressedAt, let followsTap):
            guard sample.isFnDown else {
                phase = .up
                let heldFor = sample.time - pressedAt
                let isTap = heldFor < Self.maximumTap
                let completesDoubleTap = followsTap && isTap
                lastTapEndedAt = isTap && completesDoubleTap == false ? sample.time : nil
                return .released(heldFor: heldFor, completesDoubleTap: completesDoubleTap)
            }
            if sample.hasOtherModifiers || sample.secondsSinceKeyDown < sample.time - pressedAt {
                phase = .ignoring
                return .combined
            }
            return nil
        case .ignoring:
            if sample.isFnDown == false { phase = .up }
            return nil
        }
    }
}

/// Reads the Fn key by polling, and only while the option is on.
///
/// Carbon hotkeys, which every other Syrup shortcut uses, need a non-modifier key, so they cannot express Fn alone.
/// An event tap or global key monitor could, but it would add a permission. These state reads need none.
@MainActor
final class FnKeyMonitor {
    private static let pollInterval: TimeInterval = 0.03

    var onEvent: ((FnKeyEvent) -> Void)?
    private let sample: () -> FnKeySample
    private var gesture = FnKeyGesture()
    private var timer: Timer?

    var isRunning: Bool { timer != nil }

    init(sample: @escaping () -> FnKeySample = FnKeyMonitor.systemSample) {
        self.sample = sample
    }

    func start() {
        guard timer == nil else { return }
        gesture = FnKeyGesture()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        if let event = gesture.advance(sample()) {
            onEvent?(event)
        }
    }

    nonisolated static func systemSample() -> FnKeySample {
        let others: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        return FnKeySample(
            isFnDown: CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Function)),
            hasOtherModifiers: CGEventSource.flagsState(.hidSystemState).isDisjoint(with: others) == false,
            secondsSinceKeyDown: CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .keyDown),
            time: ProcessInfo.processInfo.systemUptime
        )
    }
}
