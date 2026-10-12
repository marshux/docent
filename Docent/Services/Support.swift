import CoreTransferable
import Foundation
import Security
import UIKit
import UniformTypeIdentifiers

/// Stores the visitor's Claude API key in the iOS Keychain (this device only, never synced or backed up).
enum KeychainStore {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.marshux.docent",
        kSecAttrAccount as String: "anthropic-api-key",
    ]

    static func load() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        delete()
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

enum ImagePreparer {
    /// Longest edge sent to Claude. Camera photos are far larger than vision needs, and image
    /// cost scales with pixel area; this keeps enough detail to read a wall label.
    static let maxLongEdge: CGFloat = 1568

    static func jpeg(from image: UIImage) -> Data? {
        let longEdge = max(image.size.width, image.size.height)
        guard longEdge > 0 else { return nil }
        let scale = min(1, maxLongEdge / longEdge)
        let target = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target)) // also bakes in the photo's orientation
        }
        return resized.jpegData(compressionQuality: 0.8)
    }
}

enum TranscriptExporter {
    static func markdown(artwork: Artwork, messages: [ChatMessage], date: Date = .now) -> String {
        var lines = ["# \(artwork.title)", ""]
        if !artwork.artist.isEmpty { lines.append("- Artist: \(artwork.artist)") }
        if !artwork.year.isEmpty { lines.append("- Year: \(artwork.year)") }
        if !artwork.medium.isEmpty { lines.append("- Medium: \(artwork.medium)") }
        lines.append("- Conversation: \(date.formatted(date: .long, time: .shortened))")
        lines.append("")
        for message in messages where !message.text.isEmpty {
            let speaker = message.role == .user ? "You" : "Docent"
            lines.append("**\(speaker)** (\(message.date.formatted(date: .omitted, time: .shortened)))")
            lines.append("")
            lines.append(message.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func filename(for artwork: Artwork, date: Date = .now) -> String {
        let safeTitle = artwork.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let day = date.formatted(.iso8601.year().month().day())
        return "Docent - \(safeTitle.isEmpty ? "Artwork" : safeTitle) - \(day).md"
    }
}

/// A transcript the share sheet can save or send as a file.
struct TranscriptDocument: Transferable {
    let filename: String
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { document in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(document.filename)
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
