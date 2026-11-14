import Foundation
import Testing
@testable import Syrup

@MainActor
struct SmokeTests {
    @Test
    func idleMenuBarSymbolUsesWaveform() throws {
        let suiteName = "SyrupSmokeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(settings: AppSettings(userDefaults: defaults))

        #expect(state.menuBarSymbol == "waveform")
    }

    @Test
    func unitTestsRunInTheInertHost() {
        #expect(TestHost.isActive)
    }
}
