import Foundation
import Observation
import ServiceManagement

protocol LaunchAtLoginManaging {
    var isEnabled: Bool { get }
    var statusMessage: String { get }

    func setEnabled(_ enabled: Bool) throws
}

struct SMAppServiceLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var statusMessage: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            "Enabled"
        case .notRegistered:
            "Off"
        case .requiresApproval:
            "Requires approval in System Settings"
        case .notFound:
            "Unavailable"
        @unknown default:
            "Unavailable"
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        let status = service.status

        if enabled {
            guard status != .enabled, status != .requiresApproval else { return }
            try service.register()
        } else {
            guard status != .notRegistered else { return }
            try service.unregister()
        }
    }
}

@MainActor
@Observable
final class LaunchAtLoginController {
    private(set) var isEnabled = false
    private(set) var statusMessage = ""
    private(set) var errorMessage: String?

    @ObservationIgnored private let manager: any LaunchAtLoginManaging

    init(manager: any LaunchAtLoginManaging = SMAppServiceLaunchAtLoginManager()) {
        self.manager = manager
        refresh()
    }

    func refresh() {
        isEnabled = manager.isEnabled
        statusMessage = manager.statusMessage
    }

    func setEnabled(_ enabled: Bool) {
        do {
            try manager.setEnabled(enabled)
            errorMessage = nil
        } catch {
            errorMessage = "Launch at login could not be updated"
        }

        refresh()
    }
}
