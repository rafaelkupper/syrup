import Synchronization
import Testing
@testable import Syrup

@MainActor
struct AutoPasterTests {
    @Test
    func pasteRequiresAccessibilityTrust() {
        let autoPaster = AutoPaster(
            trustStatus: { false },
            secureInputStatus: { false },
            eventPoster: { _ in true }
        )

        #expect(throws: AutoPasteError.notTrusted) {
            try autoPaster.paste(keyCode: 9)
        }
    }

    @Test
    func pasteRefusesSecureInput() {
        let autoPaster = AutoPaster(
            trustStatus: { true },
            secureInputStatus: { true },
            eventPoster: { _ in true }
        )

        #expect(throws: AutoPasteError.secureInputActive) {
            try autoPaster.paste(keyCode: 9)
        }
    }

    @Test
    func pasteReportsEventCreationFailure() {
        let autoPaster = AutoPaster(
            trustStatus: { true },
            secureInputStatus: { false },
            eventPoster: { _ in false }
        )

        #expect(throws: AutoPasteError.eventCreationFailed) {
            try autoPaster.paste(keyCode: 9)
        }
    }

    @Test
    func requestTrustUsesInjectedRequester() {
        var requestCount = 0
        let autoPaster = AutoPaster(
            trustRequester: {
                requestCount += 1
            }
        )

        autoPaster.requestTrust()

        #expect(requestCount == 1)
    }
    @Test
    func resolvesCurrentLayoutForEveryPaste() throws {
        let layout = Mutex<UInt16>(9)
        var posted: [UInt16] = []
        let autoPaster = AutoPaster(trustStatus: { true }, secureInputStatus: { false },
            frontmostBundleURL: { nil }, keyCodeResolver: { layout.withLock { $0 } }, eventPoster: { posted.append($0); return true })
        #expect(autoPaster.strategy == .commandV(9))
        try autoPaster.paste(keyCode: 9)
        layout.withLock { $0 = 47 }
        #expect(autoPaster.strategy == .commandV(47))
        try autoPaster.paste(keyCode: 47)
        #expect(posted == [9, 47])
    }

}
