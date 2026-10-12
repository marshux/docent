import XCTest
@testable import Docent

final class StreamParserTests: XCTestCase {
    func testTextDelta() {
        let line = #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#
        XCTAssertEqual(StreamParser.event(fromLine: line), .text("Hello"))
    }

    func testStopReason() {
        let line = #"data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":3}}"#
        XCTAssertEqual(StreamParser.event(fromLine: line), .stopped(reason: "refusal"))
    }

    func testFallbackBlockRestartsTheReply() {
        let line = #"data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback"}}"#
        XCTAssertEqual(StreamParser.event(fromLine: line), .fallbackStarted)
    }

    func testErrorEvent() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        XCTAssertEqual(StreamParser.event(fromLine: line), .failed(message: "Overloaded"))
    }

    func testIgnoresEverythingElse() {
        XCTAssertNil(StreamParser.event(fromLine: "event: content_block_delta"))
        XCTAssertNil(StreamParser.event(fromLine: #"data: {"type":"ping"}"#))
        XCTAssertNil(StreamParser.event(fromLine: #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#))
        XCTAssertNil(StreamParser.event(fromLine: #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
    }
}

final class SentenceChunkerTests: XCTestCase {
    func testEmitsSentencesAsTheyComplete() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("Painted in 18"), [])
        XCTAssertEqual(chunker.append("89. It shows "), ["Painted in 1889."])
        XCTAssertEqual(chunker.append("a night sky! Really"), ["It shows a night sky!"])
        XCTAssertEqual(chunker.flush(), "Really")
        XCTAssertNil(chunker.flush())
    }

    func testDoesNotSplitInsideNumbers() {
        var chunker = SentenceChunker()
        XCTAssertEqual(chunker.append("It is 73.7 cm tall. "), ["It is 73.7 cm tall."])
    }
}

final class RequestBuildingTests: XCTestCase {
    private let artwork = Artwork(title: "The Starry Night", artist: "Vincent van Gogh", year: "1889", medium: "Oil on canvas", confidence: .high)

    func testPhotoOpensTheConversationAndEmptyTurnsAreDropped() throws {
        let turns = [
            ChatMessage(role: .user, text: "Tell me about this piece."),
            ChatMessage(role: .assistant, text: ""),
        ]
        let messages = ClaudeClient.messages(imageJPEG: Data([0xFF, 0xD8]), turns: turns)
        XCTAssertEqual(messages.count, 2)
        let first = try XCTUnwrap(messages.first?["content"] as? [[String: Any]])
        XCTAssertEqual(first.first?["type"] as? String, "image")
        XCTAssertEqual(messages.last?["content"] as? String, "Tell me about this piece.")
    }

    func testIdentificationDecodesFromSchemaShapedJSON() throws {
        let json = #"{"identified":true,"title":"The Starry Night","artist":"Vincent van Gogh","year":"1889","medium":"Oil on canvas","confidence":"high","reasoning":"Unmistakable.","alternatives":[]}"#
        let decoded = try JSONDecoder().decode(ArtworkIdentification.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.confidence, .high)
        let required = try XCTUnwrap(ClaudeClient.identificationSchema["required"] as? [String])
        XCTAssertEqual(Set(required), ["identified", "title", "artist", "year", "medium", "confidence", "reasoning", "alternatives"])
    }

    func testGuideInstructionsNameTheArtwork() {
        let text = ClaudeClient.guideInstructions(for: artwork)
        XCTAssertTrue(text.contains("\"The Starry Night\" by Vincent van Gogh, 1889, Oil on canvas"))
    }
}

final class TranscriptExporterTests: XCTestCase {
    func testMarkdownIncludesArtworkAndBothSpeakers() {
        let artwork = Artwork(title: "The Starry Night", artist: "Vincent van Gogh", year: "1889", medium: "", confidence: nil)
        let messages = [
            ChatMessage(role: .user, text: "Who painted this?"),
            ChatMessage(role: .assistant, text: "Vincent van Gogh, in 1889."),
            ChatMessage(role: .assistant, text: ""),
        ]
        let text = TranscriptExporter.markdown(artwork: artwork, messages: messages)
        XCTAssertTrue(text.hasPrefix("# The Starry Night"))
        XCTAssertTrue(text.contains("- Artist: Vincent van Gogh"))
        XCTAssertFalse(text.contains("- Medium:"))
        XCTAssertTrue(text.contains("**You**"))
        XCTAssertEqual(text.components(separatedBy: "**Docent**").count - 1, 1)
    }

    func testFilenameStripsPathCharacters() {
        let artwork = Artwork(title: "Before/After: Study", artist: "", year: "", medium: "", confidence: nil)
        let name = TranscriptExporter.filename(for: artwork)
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
        XCTAssertTrue(name.hasSuffix(".md"))
    }
}
