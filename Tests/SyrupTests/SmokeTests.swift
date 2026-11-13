import Testing
@testable import Syrup

@MainActor
struct SmokeTests {
    @Test
    func idleMenuBarSymbolUsesWaveform() {
        let state = AppState()

        #expect(state.menuBarSymbol == "waveform")
    }
}
