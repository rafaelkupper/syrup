import Foundation
import Testing
@testable import Syrup

@MainActor
struct SmokeTests {
    @Test
    func idleMenuBarSymbolUsesWaveform() throws {
        let suiteName = testDomainName("SyrupSmokeTests")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState.fixture(settings: AppSettings(userDefaults: defaults))

        #expect(state.menuBarSymbol == "waveform")
    }

    @Test
    func unitTestsRunInTheInertHost() {
        #expect(TestHost.isActive)
    }

    /// Concurrent `script/test-isolated.sh` runs each get a token in their bundle ID, and every
    /// preference domain a test creates carries it, so one run's cleanup cannot reach another's files.
    @Test
    func preferenceDomainsCarryTheRunToken() throws {
        #expect(TestRun.token(bundleIdentifier: "org.syrup.SyrupIsolatedTests.Ab12Cd34Ef56") == "Ab12Cd34Ef56")
        #expect(TestRun.token(bundleIdentifier: "org.syrup.SyrupApp") == "local")
        #expect(TestRun.token(bundleIdentifier: nil) == "local")

        let name = testDomainName("SyrupTests")
        #expect(name.hasPrefix(TestRun.domainNamespace + "."))
        let parts = name.dropFirst(TestRun.domainNamespace.count + 1).split(separator: ".", maxSplits: 2).map(String.init)
        #expect(parts.count == 3)
        #expect(parts[0] == TestRun.token)
        #expect(parts[1] == "SyrupTests")
        #expect(UUID(uuidString: parts[2]) != nil)
        if Bundle.main.bundleIdentifier?.hasPrefix(TestRun.isolatedBundlePrefix) == true {
            #expect(TestRun.token != "local")
        }
    }
}
