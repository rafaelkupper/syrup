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
    /// Chunks whose choice carries something, answer or not. These are progress: a model that reasons
    /// before it answers sends `reasoning_content`, `reasoning`, or `reasoning_details` for a while. A
    /// chunk without a choice, or with an empty or role-only delta, is not, so a server repeating
    /// them cannot hold a run open.
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
        if response.choices.contains(where: { $0.delta?.carriesSomething == true }) { progressChunks += 1 }
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
        /// A field other than `role` is non-empty: answer text, or reasoning in whatever shape the
        /// server sends it (a string, or structured `reasoning_details`), or a tool call.
        let carriesSomething: Bool

        init(from decoder: any Decoder) throws {
            let fields = try decoder.singleValueContainer().decode([String: JSONFieldValue].self)
            content = fields["content"]?.text
            // `role` names the speaker in the first chunk; it is not the model working. `content`
            // counts like any field, so a reasoning part inside it, such as Mistral's thinking chunk,
            // is progress, while a part whose text is empty is not.
            carriesSomething = fields.contains { key, value in key != "role" && value.carriesSomething }
        }
    }
}

/// Any JSON value, to tell whether a field carries something and to read `content`, which some
/// servers send as a list of typed parts instead of a string.
enum JSONFieldValue: Decodable, Sendable {
    case string(String)
    case number
    case bool
    case null
    case array([JSONFieldValue])
    case object([String: JSONFieldValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if (try? container.decode(Bool.self)) != nil {
            self = .bool
        } else if (try? container.decode(Double.self)) != nil {
            self = .number
        } else if let array = try? container.decode([JSONFieldValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONFieldValue].self))
        }
    }

    /// Whether the value holds anything generated: a non-empty string, a number or a flag, or a list or
    /// object holding one. An object's `type` and `index` only label it, so `{"type":"text","text":""}`
    /// carries nothing.
    var carriesSomething: Bool {
        switch self {
        case .string(let string): string.isEmpty == false
        case .null: false
        case .number, .bool: true
        case .array(let array): array.contains { $0.carriesSomething }
        case .object(let object): object.contains { key, value in key != "type" && key != "index" && value.carriesSomething }
        }
    }

    /// A string as it is; a list of parts as the `text` of each part, joined; anything else nil.
    var text: String? {
        switch self {
        case .string(let string):
            string
        case .array(let parts):
            parts.compactMap { part -> String? in
                guard case .object(let fields) = part, case .string(let text)? = fields["text"] else { return nil }
                return text
            }.joined()
        case .number, .bool, .null, .object:
            nil
        }
    }
}
