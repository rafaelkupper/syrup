import AVFoundation
import Foundation
import Testing
@testable import Syrup

/// Speech asset preparation per locale.
@MainActor
struct LocalePreparationTests {
    @Test func localePreparationsAreIndependentAndDeduplicated() async {
        let gate = LocalePreparationGate()
        let manager = TranscriberAssetManager(prepare: { await gate.prepare($0) })
        manager.prepareSelectedLocale("pt_BR")
        manager.prepareLocales(["pt-BR", "en-US", "en-US"])
        await eventually { await gate.count == 2 }
        #expect(await gate.count == 2)
        await gate.finish("en-US")
        await eventually { manager.assetState(forLocale: "en-US") == .installed("en-US") }
        #expect(manager.selectedLocaleAssetState == .checking)
        await gate.finish("pt-BR")
        await eventually { manager.selectedLocaleAssetState == .installed("pt-BR") }
        #expect(manager.selectedLocaleAssetState == .installed("pt-BR"))
        manager.prepareSelectedLocale("en-US")
        #expect(manager.selectedLocaleAssetState == .installed("en-US"))
        #expect(await gate.count == 2)
    }
}

private actor LocalePreparationGate {
    private var continuations: [String: CheckedContinuation<TranscriberAssetManager.AssetState, Never>] = [:]
    private(set) var count = 0
    func prepare(_ id: String) async -> TranscriberAssetManager.AssetState {
        count += 1
        return await withCheckedContinuation { continuations[id] = $0 }
    }
    func finish(_ id: String) { continuations.removeValue(forKey: id)?.resume(returning: .installed(id)) }
}
