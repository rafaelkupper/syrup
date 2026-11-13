import Foundation
import Testing
@testable import Syrup

@MainActor
struct LaunchAtLoginControllerTests {
    @Test
    func refreshMirrorsManagerStatus() {
        let manager = FakeLaunchAtLoginManager(isEnabled: true, statusMessage: "Enabled")
        let controller = LaunchAtLoginController(manager: manager)

        #expect(controller.isEnabled)
        #expect(controller.statusMessage == "Enabled")

        manager.isEnabled = false
        manager.statusMessage = "Off"
        controller.refresh()

        #expect(controller.isEnabled == false)
        #expect(controller.statusMessage == "Off")
    }

    @Test
    func setEnabledDelegatesAndRefreshesState() {
        let manager = FakeLaunchAtLoginManager(isEnabled: false, statusMessage: "Off")
        let controller = LaunchAtLoginController(manager: manager)

        controller.setEnabled(true)

        #expect(manager.requestedValues == [true])
        #expect(controller.isEnabled)
        #expect(controller.statusMessage == "Enabled")
        #expect(controller.errorMessage == nil)

        controller.setEnabled(false)

        #expect(manager.requestedValues == [true, false])
        #expect(controller.isEnabled == false)
        #expect(controller.statusMessage == "Off")
    }

    @Test
    func setEnabledFailureKeepsRefreshedStateAndShowsError() {
        let manager = FakeLaunchAtLoginManager(isEnabled: false, statusMessage: "Off")
        manager.errorToThrow = FakeLaunchAtLoginError.updateFailed
        let controller = LaunchAtLoginController(manager: manager)

        controller.setEnabled(true)

        #expect(manager.requestedValues == [true])
        #expect(controller.isEnabled == false)
        #expect(controller.statusMessage == "Off")
        #expect(controller.errorMessage == "Launch at login could not be updated")
    }
}

private enum FakeLaunchAtLoginError: Error {
    case updateFailed
}

private final class FakeLaunchAtLoginManager: LaunchAtLoginManaging {
    var isEnabled: Bool
    var statusMessage: String
    var requestedValues: [Bool] = []
    var errorToThrow: Error?

    init(isEnabled: Bool, statusMessage: String) {
        self.isEnabled = isEnabled
        self.statusMessage = statusMessage
    }

    func setEnabled(_ enabled: Bool) throws {
        requestedValues.append(enabled)

        if let errorToThrow {
            throw errorToThrow
        }

        isEnabled = enabled
        statusMessage = enabled ? "Enabled" : "Off"
    }
}
