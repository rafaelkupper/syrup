import Foundation
import Testing
@testable import Syrup

@MainActor
struct CorrectionBoundaryRegressionTests {
    @Test(arguments: ["open code's new release", "the open code-based tool"])
    func correctionsMatchWholeWordsBeforeApostropheOrHyphen(text: String) {
        let corrected = Correction.apply([.init(heard: "open code", replacement: "OpenCode")], to: text)
        #expect(corrected == text.replacingOccurrences(of: "open code", with: "OpenCode"))
    }
    @Test(arguments: [
        ("open code's new release", "OpenCode's new release"),
        ("open code’s new release", "OpenCode’s new release"),
        ("open code'S new release", "OpenCode'S new release"),
        ("open code'stuff", "open code'stuff"),
        ("open code’stuff", "open code’stuff"),
        ("pre-open code-based", "pre-OpenCode-based"),
        ("don't change don", "don't change Donald"),
        ("don’t change don", "don’t change Donald"),
        ("open code_id", "open code_id"),
    ])
    func correctionsDistinguishPossessivesFromContractions(input: String, expected: String) {
        #expect(Correction.apply([.init(heard: "open code", replacement: "OpenCode"),
                                  .init(heard: "don", replacement: "Donald")], to: input) == expected)
    }
}
