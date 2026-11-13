import Foundation
import os

private struct Fixture: Decodable {
    let id: String
    let input: String
    let language: String
    let segments: [String]
    let separators: [String]
    let quote: Bool
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

@main private struct Harness {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("usage: harness KEY_FILE ARTIFACT_DIR MODE") }
        let key = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let mode = CommandLine.arguments[3]
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: directory.appendingPathComponent("fixtures.json")))
        let outputURL = directory.appendingPathComponent("results.jsonl")
        if !FileManager.default.fileExists(atPath: outputURL.path) { FileManager.default.createFile(atPath: outputURL.path, contents: Data()) }
        let existing = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let completed = Set(existing.split(separator: "\n").compactMap { line -> String? in
            guard let row = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            return row["key"] as? String
        })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecordingProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let endpoint = OpenAICompatibleConfiguration(baseURL: URL(string: "https://api.cerebras.ai/v1")!, apiKey: key, model: "gpt-oss-120b")
        let transformer = OpenAICompatibleTransformer(configuration: endpoint, session: session)
        let chosen = fixtures.filter { f in
            if mode == "layout" { return !f.segments.isEmpty }
            if mode == "quotes-contract" { return ["quotes-en", "quotes-pt", "literal-newline", "literal-negation"].contains(f.id) }
            if mode == "streaming" { return ["newline-en", "paragraph-en", "quotes-en", "self-name-pt"].contains(f.id) }
            return true
        }
        let repeats = mode == "streaming" ? 1 : 2
        for repetition in 1...repeats {
            for fixture in chosen {
                let rowKey = "\(mode)/\(repetition)/\(fixture.id)"
                if completed.contains(rowKey) { continue }
                var row: [String: Any] = ["key": rowKey, "mode": mode, "repetition": repetition, "id": fixture.id, "requested_model": endpoint.model]
                RecordingProtocol.responseData.withLock { $0 = Data() }
                var instruction = PromptBuilder.systemPrompt(targetLanguage: fixture.language, toneInstruction: "")
                if mode == "quotes-contract" || mode == "prompt-focused" {
                    instruction = instruction.replacingOccurrences(of: PromptBuilder.outputContract, with: "Output only the result: no preamble or explanation. Preserve quotation marks requested by the speaker; do not add extra enclosing quotation marks.")
                }
                if mode == "prompt-focused" {
                    instruction += "\nTranslate the content of requested quotations into \(fixture.language) before enclosing it in quotation marks. Words mentioned as words inside a sentence are content: for example, in 'the phrase new line appears in the manual', preserve 'new line' as text instead of inserting a line break."
                }
                do {
                    let output: String
                    if mode == "layout" {
                        let layoutInstruction = "Translate each input text segment to \(fixture.language). If already in that language, keep its wording. Preserve names, meaning and punctuation. Return exactly one string per input segment in the same order; do not combine or add segments.\n" + PromptBuilder.selfCorrectionInstruction
                        let schema: [String: Any] = ["type": "object", "properties": ["segments": ["type": "array", "items": ["type": "string"]]], "required": ["segments"], "additionalProperties": false]
                        let body: [String: Any] = ["model": endpoint.model, "temperature": 0.3, "messages": [["role": "system", "content": layoutInstruction], ["role": "user", "content": String(decoding: try JSONEncoder().encode(fixture.segments), as: UTF8.self)]], "response_format": ["type": "json_schema", "json_schema": ["name": "translation_segments", "strict": true, "schema": schema]]]
                        var request = URLRequest(url: URL(string: "https://api.cerebras.ai/v1/chat/completions")!, timeoutInterval: 30)
                        request.httpMethod = "POST"
                        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.httpBody = try JSONSerialization.data(withJSONObject: body)
                        let (data,response) = try await session.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TranslationError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0) }
                        let raw = capture(data)
                        guard let text = raw["raw_output"] as? String,
                              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                              let segments = object["segments"] as? [String], segments.count == fixture.segments.count,
                              segments.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw TranslationError.invalidResponse }
                        var rendered = segments[0].trimmingCharacters(in: .whitespacesAndNewlines)
                        for index in fixture.separators.indices { rendered += fixture.separators[index] + segments[index+1].trimmingCharacters(in: .whitespacesAndNewlines) }
                        output = fixture.quote ? "\"" + rendered + "\"" : rendered
                    } else if mode == "streaming" {
                        var text = ""
                        for try await delta in transformer.transformStream(fixture.input, instruction: instruction) { text += delta }
                        output = OpenAICompatibleTransformer.normalizedModelOutput(text)
                    } else {
                        output = try await transformer.transform(fixture.input, instruction: instruction)
                    }
                    row["output"] = output
                    row["status"] = "completed"
                } catch {
                    row["status"] = "error"
                    row["error"] = String(describing: error).replacingOccurrences(of: key, with: "[REDACTED]")
                }
                let captured = RecordingProtocol.responseData.withLock { $0 }
                for (name,value) in capture(captured) { row[name] = value }
                let encoded = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
                let handle = try FileHandle(forWritingTo: outputURL)
                try handle.seekToEnd(); try handle.write(contentsOf: encoded); try handle.write(contentsOf: Data([10])); try handle.close()
                print(rowKey, row["status"] ?? "unknown"); fflush(stdout)
                if row["status"] as? String == "error" {
                    print("Stopped this arm after a request failure; result retained."); return
                }
            }
        }
    }

    private static func capture(_ data: Data) -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var result: [String: Any] = [:]
            result["response_model"] = object["model"]
            result["usage"] = object["usage"]
            if let choice = (object["choices"] as? [[String: Any]])?.first {
                result["finish_reason"] = choice["finish_reason"]
                result["raw_output"] = (choice["message"] as? [String: Any])?["content"]
            }
            return result
        }
        var text = "", model: String?, finish: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { continue }
            model = object["model"] as? String ?? model
            if let choice = (object["choices"] as? [[String: Any]])?.first {
                text += (choice["delta"] as? [String: Any])?["content"] as? String ?? ""
                finish = choice["finish_reason"] as? String ?? finish
            }
        }
        return ["raw_output": text, "response_model": model ?? "unknown", "finish_reason": finish ?? "unknown"]
    }
}
