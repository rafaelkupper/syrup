import Foundation
import Testing
@testable import Syrup

struct CorrectionTests {
    @Test(arguments: [
        ("OPEN CODE, open code!", "OpenCode, OpenCode!"),
        ("reopen code open codes open_code", "reopen code open codes open_code"),
        ("这个open code很好", "这个OpenCode很好"),
        ("用open code写", "用OpenCode写"),
        ("open code2", "open code2"),
        ("open codeé open code\u{301}", "open codeé open code\u{301}"),
    ])
    func boundaries(input: String, expected: String) {
        #expect(Correction.apply([.init(heard: "open code", replacement: "OpenCode")], to: input) == expected)
    }

    @Test func overlapAndNoCascading() {
        let rules: [Correction] = [
            .init(heard: "open", replacement: "closed"),
            .init(heard: "open code", replacement: "OpenCode"),
            .init(heard: "code then open", replacement: "combined"),
            .init(heard: "closed", replacement: "shut"),
        ]
        #expect(Correction.apply(rules, to: "open code then open") == "closed combined")
        #expect(Correction.apply([.init(heard: "I I", replacement: "I")], to: "Hi I I think") == "Hi I think")
    }

    @Test func cjkAndCanonicalMatching() {
        #expect(Correction.apply([.init(heard: "이슈", replacement: "issue")], to: "이슈를 만들었다") == "issue를 만들었다")
        #expect(Correction.apply([.init(heard: "严肃", replacement: "认真")], to: "很严肃的事") == "很认真的事")
        #expect(Correction.apply([.init(heard: "café", replacement: "coffee")], to: "CAFE\u{301}!") == "coffee!")
    }

    @Test func identityLiteralOutputAndOrder() {
        let input = "  cafe\u{301}\r\n😀\t"
        #expect(Array(Correction.apply([], to: input).utf8) == Array(input.utf8))
        #expect(Correction.apply([.init(heard: " ", replacement: "x")], to: input) == input)
        #expect(Correction.apply([.init(heard: "hex", replacement: "$1\\"), .init(heard: "HEX", replacement: "other")], to: "hex") == "$1\\")
    }

    @Test func decodingOldWorkflowAndRoundTrip() throws {
        let original = WorkflowTemplate.templates()[0].workflow(dictationLocaleID: "en-US")
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "corrections")
        let old = try JSONDecoder().decode(Workflow.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.corrections.isEmpty)
        var updated = old
        updated.corrections = [.init(heard: "open code", replacement: "OpenCode")]
        #expect(try JSONDecoder().decode(Workflow.self, from: JSONEncoder().encode(updated)) == updated)
    }
}
