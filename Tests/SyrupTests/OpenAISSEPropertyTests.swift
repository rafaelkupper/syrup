import Foundation
import Testing
@testable import Syrup

/// Generated deltas, checked against the documented rule (ARCHITECTURE.md, Translation) written out
/// independently here:
/// - the answer text is `content` when it is a string, or the joined `text` strings of its parts;
/// - a chunk is progress when its answer text is non-empty, when a part without a `text` string
///   carries a non-empty string, or when any field other than `role` and `content` does; `type` and
///   `index` only label an object, and numbers, flags, and nulls carry nothing.
/// The generator is seeded, so a failure names a case that reproduces.
struct OpenAISSEPropertyTests {
    @Test(arguments: [UInt64(1), 2, 3, 4])
    func generatedDeltasFollowTheRule(seed: UInt64) throws {
        var random = SeededRandom(seed: seed)
        var counts = (progress: 0, none: 0, text: 0)
        for index in 0..<500 {
            let delta = Self.delta(&random)
            let json = try Self.encode(["choices": [["delta": delta]]])
            var parser = OpenAISSEParser()
            let events = try parser.append("data: " + json + "\n")
            let expectedText = Self.answerText(delta["content"])
            let expectedProgress = Self.isProgress(delta)

            let text = events.compactMap { event -> String? in
                if case .delta(let text) = event { return text } else { return nil }
            }.joined()
            #expect(text == expectedText, "seed \(seed) case \(index): \(json)")
            #expect((parser.progressChunks == 1) == expectedProgress, "seed \(seed) case \(index): \(json)")
            if expectedProgress { counts.progress += 1 } else { counts.none += 1 }
            if expectedText.isEmpty == false { counts.text += 1 }
        }
        // The generator reaches every kind of case, so a pass is not vacuous.
        #expect(counts.progress > 100 && counts.none > 100 && counts.text > 50, "\(counts)")
    }

    // MARK: - The rule, written out

    static func answerText(_ content: Any?) -> String {
        if let string = content as? String { return string }
        guard let parts = content as? [Any] else { return "" }
        return parts.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined()
    }

    static func isProgress(_ delta: [String: Any]) -> Bool {
        if answerText(delta["content"]).isEmpty == false { return true }
        if let parts = delta["content"] as? [Any] {
            for part in parts {
                if let object = part as? [String: Any], object["text"] is String { continue }
                if carries(part) { return true }
            }
        }
        return delta.contains { key, value in key != "role" && key != "content" && carries(value) }
    }

    static func carries(_ value: Any) -> Bool {
        switch value {
        case let string as String: string.isEmpty == false
        case let array as [Any]: array.contains { carries($0) }
        case let object as [String: Any]: object.contains { key, value in key != "type" && key != "index" && carries(value) }
        default: false // numbers, flags, null
        }
    }

    // MARK: - Generator

    static let words = ["", "", "Hello", " there", "Plan the reply.", "{", "é"]

    static func string(_ random: inout SeededRandom) -> String { words[random.next(below: words.count)] }

    static func scalar(_ random: inout SeededRandom) -> Any {
        switch random.next(below: 5) {
        case 0: string(&random)
        case 1: random.next(below: 10)
        case 2: random.next(below: 2) == 0
        case 3: NSNull()
        default: string(&random)
        }
    }

    static func part(_ random: inout SeededRandom) -> [String: Any] {
        switch random.next(below: 5) {
        case 0: ["type": "text", "text": string(&random)]
        case 1: ["type": "text", "text": string(&random), "id": random.next(below: 2) == 0 ? "" : "part_1"]
        case 2: ["type": "thinking", "thinking": [["type": "text", "text": string(&random)]]]
        case 3: ["type": "thinking", "thinking": random.next(below: 2) == 0 ? [] as [Any] : string(&random), "closed": random.next(below: 2) == 0]
        default: ["type": "image_url", "index": random.next(below: 3), "image_url": ["url": string(&random)]]
        }
    }

    static func delta(_ random: inout SeededRandom) -> [String: Any] {
        var delta: [String: Any] = [:]
        if random.next(below: 3) == 0 { delta["role"] = random.next(below: 2) == 0 ? "assistant" : "" }
        switch random.next(below: 4) {
        case 0: delta["content"] = string(&random)
        case 1: delta["content"] = (0..<random.next(below: 4)).map { _ in part(&random) }
        case 2: delta["content"] = NSNull()
        default: break
        }
        for key in ["reasoning", "reasoning_content", "refusal", "x_tokens", "x_partial"] where random.next(below: 4) == 0 {
            delta[key] = scalar(&random)
        }
        if random.next(below: 5) == 0 {
            delta["reasoning_details"] = [["type": "reasoning.text", "index": 0, "text": string(&random)]]
        }
        if random.next(below: 5) == 0 {
            var function: [String: Any] = ["arguments": string(&random)]
            if random.next(below: 2) == 0 { function["name"] = string(&random) }
            delta["tool_calls"] = [["index": random.next(below: 2), "function": function]]
        }
        return delta
    }

    static func encode(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
}

/// SplitMix64: a fixed seed gives the same sequence on every run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func next(below bound: Int) -> Int { Int(next() % UInt64(bound)) }
}
