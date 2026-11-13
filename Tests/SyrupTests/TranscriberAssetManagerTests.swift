import Foundation
import Testing
@testable import Syrup

@MainActor
struct TranscriberAssetManagerTests {
    @Test
    func bcp47ComparisonTreatsUnderscoreAndHyphenLocaleIDsAsEquivalent() {
        let installedLocales = [Locale(identifier: "pt-BR")]

        #expect(TranscriberAssetManager.locales(
            installedLocales,
            contain: Locale(identifier: "pt_BR")
        ))
    }

    @Test
    func downloadingStateExposesMessageAndProgress() {
        let manager = TranscriberAssetManager()

        manager.selectedLocaleAssetState = .downloading("Portuguese (Brazil)", 0.42)

        #expect(manager.selectedLocaleAssetMessage == "Downloading Portuguese (Brazil) language model...")
        #expect(manager.selectedLocaleProgress == 0.42)
    }

    @Test
    func installedStateHasNoProgressValue() {
        let manager = TranscriberAssetManager()

        manager.selectedLocaleAssetState = .installed("Portuguese (Brazil)")

        #expect(manager.selectedLocaleAssetMessage == "Portuguese (Brazil) language model ready")
        #expect(manager.selectedLocaleProgress == nil)
    }

    @Test
    func installedLocaleCacheReturnsNormalizedLocale() {
        var cache = TranscriberInstalledLocaleCache()
        cache.storeInstalled(Locale(identifier: "pt-BR"))

        let cachedLocale = cache.installedLocale(equivalentTo: Locale(identifier: "pt_BR"))

        #expect(cachedLocale?.identifier(.bcp47) == "pt-BR")

        cache.remove(Locale(identifier: "pt_BR"))

        #expect(cache.installedLocale(equivalentTo: Locale(identifier: "pt-BR")) == nil)
    }

}
