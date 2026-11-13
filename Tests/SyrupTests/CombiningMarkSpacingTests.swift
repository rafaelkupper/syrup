import Foundation
import Testing
@testable import Syrup

@MainActor
struct CombiningMarkSpacingTests {
    @Test(arguments: ["\u{FE0F}", "\u{20E3}", "\u{301}"])
    func combiningMarksDoNotTriggerSpacing(unit: String) {
        #expect(!DeliveryTarget.isWordCharacter(unit))
    }

    @Test(arguments: ["❤️", "1️⃣", "e\u{301}"])
    func lastUnitOfEmojiOrDecomposedAccentIsUnspaced(text: String) throws {
        let unit = try #require(text.utf16.last)
        let scalar = try #require(UnicodeScalar(unit))
        #expect(!DeliveryTarget.isWordCharacter(String(scalar)))
        #expect(DeliveryTarget.isWordCharacter("é"))
    }
}
