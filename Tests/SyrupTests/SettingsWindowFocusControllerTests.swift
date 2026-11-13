import Testing
@testable import Syrup

@MainActor
struct SettingsWindowFocusControllerTests {
    @Test
    func refocusActivatesAppAndOrdersVisibleWindowsOnly() {
        var activationCount = 0
        let visibleWindow = FakeSettingsWindow(isVisible: true)
        let hiddenWindow = FakeSettingsWindow(isVisible: false)
        let controller = SettingsWindowFocusController(
            activateApplication: {
                activationCount += 1
            },
            windows: {
                [visibleWindow, hiddenWindow]
            }
        )

        controller.refocusVisibleWindows()

        #expect(activationCount == 1)
        #expect(visibleWindow.orderFrontCount == 1)
        #expect(hiddenWindow.orderFrontCount == 0)
    }
}

@MainActor
private final class FakeSettingsWindow: SettingsWindowRefocusable {
    let isVisible: Bool
    private(set) var orderFrontCount = 0

    init(isVisible: Bool) {
        self.isVisible = isVisible
    }

    func makeKeyAndOrderFront() {
        orderFrontCount += 1
    }
}
