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
        var keyCode: UInt16 = 9
        var posted: [UInt16] = []
        let autoPaster = AutoPaster(trustStatus: { true }, secureInputStatus: { false },
            frontmostBundleURL: { nil }, keyCodeResolver: { keyCode }, eventPoster: { posted.append($0); return true })
        #expect(autoPaster.strategy == .commandV(9))
        try autoPaster.paste(keyCode: keyCode)
        keyCode = 47
        #expect(autoPaster.strategy == .commandV(47))
        try autoPaster.paste(keyCode: keyCode)
        #expect(posted == [9, 47])
    }

}
