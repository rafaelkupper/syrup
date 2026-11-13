import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum AutoPasteError: Error, Equatable {
    case notTrusted
    case secureInputActive
    case eventCreationFailed
}

@MainActor
protocol AutoPasting: AnyObject {
    var isTrusted: Bool { get }
    func requestTrust()
    var strategy: PasteStrategy { get }
    func paste(keyCode: CGKeyCode) throws
}

@MainActor
final class AutoPaster: AutoPasting {
    private let trustStatus: () -> Bool
    private let trustRequester: () -> Void
    private let secureInputStatus: () -> Bool
    private let keyCodeResolver: @MainActor () -> CGKeyCode
    private let frontmostBundleURL: @MainActor () -> URL?
    private let eventPoster: (CGKeyCode) -> Bool

    init(
        trustStatus: @escaping () -> Bool = { AXIsProcessTrusted() },
        trustRequester: @escaping () -> Void = {
            let options = [
                "AXTrustedCheckOptionPrompt": true
            ] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        secureInputStatus: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        frontmostBundleURL: @escaping @MainActor () -> URL? = {
            NSWorkspace.shared.frontmostApplication?.bundleURL
        },
        keyCodeResolver: @escaping @MainActor () -> CGKeyCode = PasteKeyResolver.currentKeyCode,
        eventPoster: @escaping (CGKeyCode) -> Bool = { keyCode in
            let source = CGEventSource(stateID: .combinedSessionState)
            guard
                let keyDown = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: keyCode,
                    keyDown: true
                ),
                let keyUp = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: keyCode,
                    keyDown: false
                )
            else {
                return false
            }

            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            return true
        }
    ) {
        self.trustStatus = trustStatus
        self.trustRequester = trustRequester
        self.secureInputStatus = secureInputStatus
        self.frontmostBundleURL = frontmostBundleURL
        self.keyCodeResolver = keyCodeResolver
        self.eventPoster = eventPoster
    }

    var isTrusted: Bool {
        trustStatus()
    }

    func requestTrust() {
        trustRequester()
    }

    var strategy: PasteStrategy {
        PasteStrategy.resolve(for: frontmostBundleURL(), keyCode: keyCodeResolver())
    }

    func paste(keyCode: CGKeyCode) throws {
        guard isTrusted else {
            throw AutoPasteError.notTrusted
        }

        guard secureInputStatus() == false else {
            throw AutoPasteError.secureInputActive
        }

        guard eventPoster(keyCode) else {
            throw AutoPasteError.eventCreationFailed
        }
    }
}
