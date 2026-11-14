import Foundation

enum OpenAISSEEvent: Equatable, Sendable {
    case delta(String)
    case done
}

struct OpenAISSEParser: Sendable {
    private var buffer = ""
    private var endedWithCarriageReturn = false
    private(set) var didReceiveDone = false
    /// A chunk said `finish_reason: stop`: the answer is complete even if the server closes the
    /// stream without sending `[DONE]`, as some do.
    private(set) var didReceiveStop = false
    /// `data:` chunks parsed so far, whatever they carry.
    private(set) var dataChunks = 0
    /// Chunks whose choice carries text, answer or not. These are progress: a model that reasons
    /// before it answers sends `reasoning_content` or `reasoning` for a while. A chunk without a
    /// choice, or with an empty delta, is not, so a server repeating them cannot hold a run open.
    private(set) var progressChunks = 0

    mutating func append(_ chunk: String) throws -> [OpenAISSEEvent] {
        guard didReceiveDone == false else { return [] }

        var events: [OpenAISSEEvent] = []
        for scalar in chunk.unicodeScalars {
            if scalar == "\n", endedWithCarriageReturn {
                endedWithCarriageReturn = false
                continue
            }
            endedWithCarriageReturn = scalar == "\r"
            if scalar == "\n" || scalar == "\r" {
                let line = buffer
                buffer = ""
                events.append(contentsOf: try parse(line))
                if didReceiveDone { break }
            } else {
                buffer.unicodeScalars.append(scalar)
            }
        }

        return events
    }

    mutating func finish() throws -> [OpenAISSEEvent] {
        guard didReceiveDone == false, buffer.isEmpty == false else { return [] }

        let line = buffer
        buffer = ""
        return try parse(line)
    }

    private mutating func parse(_ line: String) throws -> [OpenAISSEEvent] {
        guard line.hasPrefix("data:") else { return [] }

        let payload = line.dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)
        guard payload.isEmpty == false else { return [] }
        if payload == "[DONE]" {
            didReceiveDone = true
            return [.done]
        }

        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: Data(payload.utf8))
        } catch {
            throw TranslationError.invalidResponse
        }
        dataChunks += 1

        // A router can report a provider failure mid-stream, then still send `[DONE]`.
        guard response.reportsError == false else { throw TranslationError.providerReportedError }
        if response.choices.contains(where: { $0.delta?.carriesText == true }) { progressChunks += 1 }
        try OpenAICompatibleTransformer.validateFinishReason(response.choices.first?.finishReason)
        if response.choices.first?.finishReason == "stop" { didReceiveStop = true }
        guard let content = response.choices.first?.delta?.content,
              content.isEmpty == false else {
            return []
        }
        return [.delta(content)]
    }

    private struct Response: Decodable {
        let choices: [Choice]
        /// The chunk carries an `error` object, with or without `choices`.
        let reportsError: Bool

        enum CodingKeys: String, CodingKey {
            case choices, error
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            reportsError = try container.contains(.error) && container.decodeNil(forKey: .error) == false
            // A chunk may carry neither, such as a usage-only chunk; it is skipped.
            choices = reportsError ? [] : try container.decodeIfPresent([Choice].self, forKey: .choices) ?? []
        }
    }

    private struct Choice: Decodable {
        /// Some servers send the final `finish_reason` chunk without a `delta`.
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    private struct Delta: Decodable {
        let content: String?
        /// A field other than `role` holds non-empty text: the answer, or reasoning under whatever
        /// name the server uses.
        let carriesText: Bool

        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            content = try container.decodeIfPresent(String.self, forKey: AnyKey(stringValue: "content"))
            // `role` names the speaker in the first chunk; it is not generated text.
            carriesText = container.allKeys.contains { key in
                key.stringValue != "role" && (try? container.decode(String.self, forKey: key))?.isEmpty == false
            }
        }
    }
}
