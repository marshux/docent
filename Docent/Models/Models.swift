import Foundation

/// What Claude returns when asked to identify a photographed artwork.
/// Field names match the JSON schema in `ClaudeClient.identificationSchema`.
struct ArtworkIdentification: Codable, Equatable {
    enum Confidence: String, Codable {
        case high, medium, low
    }

    struct Alternative: Codable, Equatable, Identifiable {
        var title: String
        var artist: String
        var id: String { "\(title)|\(artist)" }
    }

    /// False when Claude could not name a specific work; `title` is then a description.
    var identified: Bool
    var title: String
    var artist: String
    var year: String
    var medium: String
    var confidence: Confidence
    /// One or two sentences, shown to the visitor, on why this confidence level.
    var reasoning: String
    var alternatives: [Alternative]
}

/// The artwork the visitor confirmed (possibly after correcting the identification).
struct Artwork: Equatable {
    var title: String
    var artist: String
    var year: String
    var medium: String
    /// How sure the identification was when the visitor accepted it; nil if they typed it in themselves.
    var confidence: ArtworkIdentification.Confidence?

    var headline: String {
        artist.isEmpty ? title : "\(title), \(artist)"
    }
}

struct ChatMessage: Identifiable, Equatable {
    enum Role: String {
        case user, assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    let date = Date()
}
