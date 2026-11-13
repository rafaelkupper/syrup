import AppKit
import Foundation

@MainActor
protocol SettingsWindowRefocusable: AnyObject {
    var isVisible: Bool { get }
    func makeKeyAndOrderFront()
}

extension NSWindow: SettingsWindowRefocusable {
    func makeKeyAndOrderFront() {
        makeKeyAndOrderFront(nil)
    }
}

@MainActor
struct SettingsWindowFocusController {
    private let activateApplication: @MainActor () -> Void
    private let windows: @MainActor () -> [any SettingsWindowRefocusable]
    private let sleeper: @Sendable (UInt64) async throws -> Void

    init(
        activateApplication: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        },
        windows: @escaping @MainActor () -> [any SettingsWindowRefocusable] = {
            NSApp.windows
        },
        sleeper: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.activateApplication = activateApplication
        self.windows = windows
        self.sleeper = sleeper
    }

    func refocusVisibleWindows() {
        activateApplication()
        for window in windows() where window.isVisible {
            window.makeKeyAndOrderFront()
        }
    }

    func refocusVisibleWindows(afterNanoseconds delay: UInt64) {
        Task { @MainActor in
            if delay > 0 {
                try? await sleeper(delay)
            }
            refocusVisibleWindows()
        }
    }
}
