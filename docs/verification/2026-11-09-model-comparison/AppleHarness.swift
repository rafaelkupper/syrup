import Foundation
import FoundationModels

// Runs each fixture through Syrup's real AppleOnDeviceTransformer and PromptBuilder.
// Raw text is captured before ModelOutputNormalizer; "output" is what Syrup delivers.

private struct Fixture: Decodable {
    let id: String
    let input: String
    let language: String
}

@main private struct AppleHarness {
    static func main() async throws {
        guard CommandLine.arguments.count == 3, let repeats = Int(CommandLine.arguments[2]) else {
            fatalError("usage: harness ARTIFACT_DIR REPEATS")
        }
        guard case .available = SystemLanguageModel.default.availability else {
            print("Apple on-device model unavailable: \(SystemLanguageModel.default.availability)"); return
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: directory.appendingPathComponent("fixtures.json")))
        let outputURL = directory.appendingPathComponent("results.jsonl")
        if !FileManager.default.fileExists(atPath: outputURL.path) { FileManager.default.createFile(atPath: outputURL.path, contents: Data()) }
        let existing = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let completed = Set(existing.split(separator: "\n").compactMap { line -> String? in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  row["status"] as? String == "completed" else { return nil }
            return row["key"] as? String
        })
        let model = "apple-on-device"
        for repetition in 1...repeats {
            for fixture in fixtures {
                let rowKey = "\(model)/\(repetition)/\(fixture.id)"
                if completed.contains(rowKey) { continue }
                var row: [String: Any] = ["key": rowKey, "model": model, "repetition": repetition, "id": fixture.id]
                let instruction = PromptBuilder.systemPrompt(targetLanguage: fixture.language, toneInstruction: "")
                // Production prepares a fresh session per run with the instruction, then prewarms.
                let transformer = AppleOnDeviceTransformer(instruction: instruction, shouldPrewarm: false)
                OpenAICompatibleTransformer.lastRaw.withLock { $0 = "" }
                let started = ContinuousClock.now
                do {
                    _ = try await transformer.transform(fixture.input, instruction: instruction)
                    let raw = OpenAICompatibleTransformer.lastRaw.withLock { $0 }
                    row["raw_output"] = raw
                    row["output"] = ModelOutputNormalizer.normalize(
                        raw,
                        keepsWrapperQuotes: ModelOutputNormalizer.requestsQuotes(input: fixture.input, instruction: instruction)
                    )
                    row["status"] = "completed"
                    row["finish_reason"] = "stop"
                } catch {
                    row["status"] = "error"
                    row["error"] = String(describing: error)
                }
                let elapsed = ContinuousClock.now - started
                row["duration_ms"] = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                row["response_model"] = model
                let encoded = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
                let handle = try FileHandle(forWritingTo: outputURL)
                try handle.seekToEnd(); try handle.write(contentsOf: encoded); try handle.write(contentsOf: Data([10])); try handle.close()
                print(rowKey, row["status"] ?? "unknown", row["duration_ms"] ?? ""); fflush(stdout)
            }
        }
    }
}
