import Foundation
import os

// Runs each fixture through Syrup's real OpenAICompatibleTransformer and PromptBuilder
// against one Cerebras model. Records the raw model text, what Syrup delivers after
// normalization, the response model, finish reason, token usage, and wall-clock time.
// Never records the key, reasoning text, or request headers.

private struct Fixture: Decodable {
    let id: String
    let input: String
    let language: String
}

private final class RecordingProtocol: URLProtocol, @unchecked Sendable {
    static let responseData = OSAllocatedUnfairLock(initialState: Data())
    private let forwardingTask = OSAllocatedUnfairLock(initialState: Optional<URLSessionDataTask>.none)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        if forwarded.httpBody == nil, let stream = forwarded.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            forwarded.httpBodyStream = nil
            forwarded.httpBody = body
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        let session = URLSession(configuration: config)
        let operation = session.dataTask(with: forwarded) { [self] data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error { client?.urlProtocol(self, didFailWithError: error); return }
            guard let response else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
            let data = data ?? Data()
            Self.responseData.withLock { $0 = data }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        forwardingTask.withLock { $0 = operation }
        operation.resume()
    }
    override func stopLoading() { forwardingTask.withLock { $0?.cancel(); $0 = nil } }
}

@main private struct CerebrasHarness {
    static func main() async throws {
        guard CommandLine.arguments.count == 4, let repeats = Int(CommandLine.arguments[3]) else {
            fatalError("usage: CEREBRAS_API_KEY=... harness ARTIFACT_DIR MODEL REPEATS")
        }
        guard let key = ProcessInfo.processInfo.environment["CEREBRAS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), key.isEmpty == false else {
            fatalError("CEREBRAS_API_KEY is not set; run.sh reads it from the repository's .env")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let model = CommandLine.arguments[2]
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: directory.appendingPathComponent("fixtures.json")))
        let outputURL = directory.appendingPathComponent("results.jsonl")
        if !FileManager.default.fileExists(atPath: outputURL.path) { FileManager.default.createFile(atPath: outputURL.path, contents: Data()) }
        let existing = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let completed = Set(existing.split(separator: "\n").compactMap { line -> String? in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  row["status"] as? String == "completed" else { return nil }
            return row["key"] as? String
        })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let endpoint = OpenAICompatibleConfiguration(baseURL: URL(string: "https://api.cerebras.ai/v1")!, apiKey: key, model: model)
        let transformer = OpenAICompatibleTransformer(configuration: endpoint, session: session)
        var failures = 0
        for repetition in 1...repeats {
            for fixture in fixtures {
                let rowKey = "\(model)/\(repetition)/\(fixture.id)"
                if completed.contains(rowKey) { continue }
                var row: [String: Any] = ["key": rowKey, "model": model, "repetition": repetition, "id": fixture.id]
                RecordingProtocol.responseData.withLock { $0 = Data() }
                let instruction = PromptBuilder.systemPrompt(targetLanguage: fixture.language, toneInstruction: "")
                let started = ContinuousClock.now
                do {
                    row["output"] = try await transformer.transform(fixture.input, instruction: instruction)
                    row["status"] = "completed"
                } catch {
                    row["status"] = "error"
                    row["error"] = String(describing: error).replacingOccurrences(of: key, with: "[REDACTED]")
                    failures += 1
                }
                let elapsed = ContinuousClock.now - started
                row["duration_ms"] = Int(elapsed.components.seconds * 1000) + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                for (name, value) in capture(RecordingProtocol.responseData.withLock { $0 }) { row[name] = value }
                let encoded = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
                let handle = try FileHandle(forWritingTo: outputURL)
                try handle.seekToEnd(); try handle.write(contentsOf: encoded); try handle.write(contentsOf: Data([10])); try handle.close()
                print(rowKey, row["status"] ?? "unknown", row["duration_ms"] ?? ""); fflush(stdout)
                if failures >= 3 { print("Stopped after three request failures; results retained."); return }
            }
        }
    }

    private static func capture(_ data: Data) -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: Any] = [:]
        result["response_model"] = object["model"]
        result["usage"] = object["usage"]
        if let choice = (object["choices"] as? [[String: Any]])?.first {
            result["finish_reason"] = choice["finish_reason"]
            result["raw_output"] = (choice["message"] as? [String: Any])?["content"]
        }
        return result
    }
}
