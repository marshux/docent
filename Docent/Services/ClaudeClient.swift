import Foundation

/// Models the visitor can pick in Settings. Raw values are Claude API model IDs.
enum ClaudeModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    static let `default` = ClaudeModel.opus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus: "Claude Opus 5.5"
        case .sonnet: "Claude Sonnet 5.5"
        case .haiku: "Claude Haiku 5.5"
        }
    }

    var detail: String {
        switch self {
        case .opus: "Most knowledgeable. Best at recognising artworks."
        case .sonnet: "Faster and about half the cost."
        case .haiku: "Fastest and cheapest. Least reliable at identification."
        }
    }

    /// Server-side refusal fallbacks (`fallbacks: "default"`) exist for Opus and Sonnet, not Haiku.
    var supportsServerFallback: Bool { self != .haiku }
}

enum ClaudeError: LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case rateLimited
    case overloaded
    case refused
    case truncated
    case badResponse
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingKey: "Add your Claude API key in Settings first."
        case .invalidKey: "Claude rejected the API key. Check it in Settings."
        case .rateLimited: "Your API key hit its rate limit. Wait a moment and try again."
        case .overloaded: "Claude is overloaded right now. Try again in a moment."
        case .refused: "Claude declined to answer that."
        case .truncated: "The answer was cut off before it finished. Try again."
        case .badResponse: "Claude sent back something unexpected. Try again."
        case .api(let status, let message): "Claude API error \(status): \(message)"
        }
    }
}

/// One piece of a streamed chat reply.
enum ReplyChunk: Equatable {
    case text(String)
    /// The first model declined mid-answer and a fallback model is starting over:
    /// throw away any text received so far.
    case restart
}

/// One parsed line of the Messages API server-sent-event stream.
enum StreamEvent: Equatable {
    case text(String)
    case fallbackStarted
    case stopped(reason: String)
    case failed(message: String)
}

enum StreamParser {
    /// Parses a single SSE line. Returns nil for lines that carry nothing we act on
    /// (`event:` lines, pings, thinking deltas, block starts/stops, and so on).
    static func event(fromLine line: String) -> StreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return nil }

        switch type {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return nil }
            return .text(text)
        case "content_block_start":
            let block = object["content_block"] as? [String: Any]
            return block?["type"] as? String == "fallback" ? .fallbackStarted : nil
        case "message_delta":
            guard let delta = object["delta"] as? [String: Any],
                  let reason = delta["stop_reason"] as? String
            else { return nil }
            return .stopped(reason: reason)
        case "error":
            let error = object["error"] as? [String: Any]
            return .failed(message: error?["message"] as? String ?? "Unknown stream error")
        default:
            return nil
        }
    }
}

/// Minimal Claude Messages API client over raw HTTPS (there is no official Swift SDK).
/// The key is the visitor's own, read from the Keychain, and is sent only to api.anthropic.com.
struct ClaudeClient {
    let apiKey: String
    let model: ClaudeModel
    var session: URLSession = .shared

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let fallbackBeta = "server-side-fallback-2026-07-01"

    // MARK: Identification

    /// Asks Claude which artwork is in the photo. `titleHint` is whatever the visitor typed, if anything.
    func identify(imageJPEG: Data, titleHint: String?) async throws -> ArtworkIdentification {
        var prompt = """
        A museum visitor took this photo of an artwork. Identify the specific work.

        Use everything visible: the work itself, any signature, and any wall label or caption in the frame.
        """
        if let hint = titleHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            prompt += """


            The visitor says the title is: "\(hint)". Treat that as a strong hint, but check it against \
            what you can see and say so in your reasoning if it does not match.
            """
        }
        prompt += """


        Confidence levels:
        - high: you recognise this exact work.
        - medium: probably this work, but it could be another version, a copy, or a similar piece by the same artist.
        - low: you are inferring from style or subject and could easily be wrong.

        If you cannot name a specific work, set identified to false, put a short description in title \
        (for example "Unidentified Dutch still life"), and give your best guess at the artist or "Unknown".
        Use an empty string for a year or medium you do not know rather than guessing.
        When confidence is not high, list up to three other works it could plausibly be in alternatives; otherwise leave it empty.
        Keep reasoning to one or two plain sentences; it is shown to the visitor.
        """

        var body = baseBody(effort: "medium")
        body["max_tokens"] = 16000
        let content: [[String: Any]] = [Self.imageBlock(imageJPEG), ["type": "text", "text": prompt]]
        let message: [String: Any] = ["role": "user", "content": content]
        body["messages"] = [message]
        let format: [String: Any] = ["type": "json_schema", "schema": Self.identificationSchema]
        body["output_config"] = ["effort": "medium", "format": format] as [String: Any]

        let (data, response) = try await session.data(for: try request(body: body))
        try Self.check(response, body: data)

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.badResponse
        }
        // A declined request is an HTTP 200 with stop_reason "refusal": check before reading content.
        switch object["stop_reason"] as? String {
        case "refusal": throw ClaudeError.refused
        case "max_tokens": throw ClaudeError.truncated
        default: break
        }
        let blocks = object["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
              let json = text.data(using: .utf8),
              let identification = try? JSONDecoder().decode(ArtworkIdentification.self, from: json)
        else { throw ClaudeError.badResponse }
        return identification
    }

    // MARK: Conversation

    /// Streams Claude's next reply. `turns` is the conversation so far, ending with the visitor's latest message.
    func streamReply(artwork: Artwork, imageJPEG: Data, turns: [ChatMessage]) -> AsyncThrowingStream<ReplyChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var body = baseBody(effort: "low") // spoken answers: favour responsiveness
                    body["max_tokens"] = 16000
                    body["stream"] = true
                    body["system"] = Self.guideInstructions(for: artwork)
                    // The photo and history are resent every turn; cache the growing prefix.
                    body["cache_control"] = ["type": "ephemeral"] as [String: Any]
                    body["messages"] = Self.messages(imageJPEG: imageJPEG, turns: turns)

                    let (bytes, response) = try await session.bytes(for: try request(body: body))
                    if (response as? HTTPURLResponse)?.statusCode != 200 {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        try Self.check(response, body: data)
                    }

                    var stopReason: String?
                    for try await line in bytes.lines {
                        switch StreamParser.event(fromLine: line) {
                        case .text(let text): continuation.yield(.text(text))
                        case .fallbackStarted: continuation.yield(.restart)
                        case .stopped(let reason): stopReason = reason
                        case .failed(let message): throw ClaudeError.api(status: 200, message: message)
                        case nil: break
                        }
                    }
                    switch stopReason {
                    case "refusal": throw ClaudeError.refused
                    case "max_tokens": throw ClaudeError.truncated
                    default: continuation.finish()
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Request building

    static func guideInstructions(for artwork: Artwork) -> String {
        var details = "\"\(artwork.title)\""
        if !artwork.artist.isEmpty { details += " by \(artwork.artist)" }
        if !artwork.year.isEmpty { details += ", \(artwork.year)" }
        if !artwork.medium.isEmpty { details += ", \(artwork.medium)" }

        let certainty = switch artwork.confidence {
        case .high: "The identification was made from the photo with high confidence and the visitor confirmed it."
        case .medium: "The identification from the photo was only moderately confident; the visitor accepted it, but it could be a different version or a similar work."
        case .low: "The identification from the photo was a low-confidence guess that the visitor accepted. Be open about that when it matters."
        case nil: "The visitor supplied or corrected these details themselves, so trust them over your own reading of the photo."
        }

        return """
        You are Docent, a warm and knowledgeable museum guide. A visitor is standing in front of an artwork \
        and talking with you out loud. Everything you write is read to them by a speech synthesizer.

        The artwork: \(details). \(certainty) The visitor's photo of it is attached to the first message.

        Because your words are spoken aloud:
        - Write the way a good guide talks: plain sentences, no markdown, lists, headings or emoji, since those would be read out literally.
        - Keep each answer to about three to five sentences unless the visitor asks for more. They can always ask a follow-up.

        What the visitor wants is the history around this piece: who made it and why, what was happening at the time, \
        how it was made, where it has been, and how people reacted to it. Point out details they can see in front of them.

        Being right matters more than telling a good story. If you are unsure of a date, an attribution or an anecdote, \
        say so rather than filling the gap, and do not invent provenance.

        The visitor's questions come through speech recognition, so they may contain misheard words. \
        Read them charitably, and ask if a question really does not make sense.
        """
    }

    static func messages(imageJPEG: Data, turns: [ChatMessage]) -> [[String: Any]] {
        // The photo opens the conversation; the API merges it with the visitor's first question.
        let opening: [[String: Any]] = [imageBlock(imageJPEG), ["type": "text", "text": "Here is my photo of the artwork."]]
        var messages: [[String: Any]] = [["role": "user", "content": opening]]
        for turn in turns where !turn.text.isEmpty {
            messages.append(["role": turn.role.rawValue, "content": turn.text])
        }
        return messages
    }

    private static func imageBlock(_ jpeg: Data) -> [String: Any] {
        let source: [String: Any] = ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]
        return ["type": "image", "source": source]
    }

    /// Structured-output schema for identification. Every object needs `additionalProperties: false`.
    static let identificationSchema: [String: Any] = {
        let string: [String: Any] = ["type": "string"]
        let alternative: [String: Any] = [
            "type": "object",
            "properties": ["title": string, "artist": string],
            "required": ["title", "artist"],
            "additionalProperties": false,
        ]
        let confidence: [String: Any] = ["type": "string", "enum": ["high", "medium", "low"]]
        let alternatives: [String: Any] = ["type": "array", "items": alternative]
        let boolean: [String: Any] = ["type": "boolean"]
        let properties: [String: Any] = [
            "identified": boolean,
            "title": string,
            "artist": string,
            "year": string,
            "medium": string,
            "confidence": confidence,
            "reasoning": string,
            "alternatives": alternatives,
        ]
        return [
            "type": "object",
            "properties": properties,
            "required": ["identified", "title", "artist", "year", "medium", "confidence", "reasoning", "alternatives"],
            "additionalProperties": false,
        ]
    }()

    /// Fields shared by both calls. Thinking is left at the model default (adaptive); `effort` controls depth.
    private func baseBody(effort: String) -> [String: Any] {
        let outputConfig: [String: Any] = ["effort": effort]
        var body: [String: Any] = ["model": model.rawValue, "output_config": outputConfig]
        if model.supportsServerFallback {
            // If a safety classifier declines, let the API retry on its recommended fallback model.
            body["fallbacks"] = "default"
        }
        return body
    }

    private func request(body: [String: Any]) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw ClaudeError.missingKey }
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if model.supportsServerFallback {
            request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse }
        guard http.statusCode != 200 else { return }
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = (object?["error"] as? [String: Any])?["message"] as? String ?? "No details"
        switch http.statusCode {
        case 401, 403: throw ClaudeError.invalidKey
        case 429: throw ClaudeError.rateLimited
        case 529: throw ClaudeError.overloaded
        default: throw ClaudeError.api(status: http.statusCode, message: message)
        }
    }
}
