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

        try OpenAICompatibleTransformer.validateFinishReason(response.choices.first?.finishReason)
        if response.choices.first?.finishReason == "stop" { didReceiveStop = true }
        guard let content = response.choices.first?.delta.content,
              content.isEmpty == false else {
            return []
        }
        return [.delta(content)]
    }

    private struct Response: Decodable {
        let choices: [Choice]
    }

    private struct Choice: Decodable {
        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    private struct Delta: Decodable {
        let content: String?
    }
}
