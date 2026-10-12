import Observation
import SwiftUI
import UIKit

/// All app state: the key, the current photo and identification, and the conversation.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        case capture, confirm, conversation
    }

    private(set) var phase: Phase = .capture
    private(set) var apiKey: String
    var model: ClaudeModel {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: Self.modelDefaultsKey) }
    }
    var speakReplies = true {
        didSet { if !speakReplies { speaker.stop() } }
    }

    private(set) var photo: UIImage?
    private(set) var identification: ArtworkIdentification?
    private(set) var artwork: Artwork?
    private(set) var messages: [ChatMessage] = []
    private(set) var isIdentifying = false
    private(set) var isResponding = false
    var errorMessage: String?

    let speaker = SpeechSynthesizer()
    let recognizer = SpeechRecognizer()

    @ObservationIgnored private var photoJPEG: Data?
    @ObservationIgnored private var replyTask: Task<Void, Never>?
    private static let modelDefaultsKey = "claudeModel"

    init() {
        apiKey = KeychainStore.load() ?? ""
        let saved = UserDefaults.standard.string(forKey: Self.modelDefaultsKey)
        model = saved.flatMap(ClaudeModel.init(rawValue:)) ?? .default
    }

    var hasAPIKey: Bool { !apiKey.isEmpty }

    private var client: ClaudeClient { ClaudeClient(apiKey: apiKey, model: model) }

    // MARK: API key

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if KeychainStore.save(trimmed) {
            apiKey = trimmed
        } else {
            errorMessage = "Couldn't save the key to the Keychain."
        }
    }

    func deleteAPIKey() {
        KeychainStore.delete()
        apiKey = ""
        startOver()
    }

    // MARK: Identification

    func identify(_ image: UIImage, titleHint: String) async {
        guard let jpeg = ImagePreparer.jpeg(from: image) else {
            errorMessage = "Couldn't read that photo. Try another one."
            return
        }
        photo = image
        photoJPEG = jpeg
        isIdentifying = true
        defer { isIdentifying = false }
        do {
            identification = try await client.identify(imageJPEG: jpeg, titleHint: titleHint)
            phase = .confirm
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The visitor accepted (or corrected) the identification: start the conversation.
    func confirm(_ artwork: Artwork) {
        self.artwork = artwork
        messages = []
        phase = .conversation
        try? AudioSession.configure()
        replyTask = Task {
            await respond(to: "Tell me about this piece.")
        }
    }

    func startOver() {
        replyTask?.cancel()
        speaker.stop()
        Task { _ = await recognizer.stop() }
        photo = nil
        photoJPEG = nil
        identification = nil
        artwork = nil
        messages = []
        isResponding = false
        phase = .capture
    }

    // MARK: Conversation

    func send(_ text: String) {
        guard !isResponding else { return }
        replyTask = Task { await respond(to: text) }
    }

    /// Tap once to start listening, again to stop and send what was heard.
    func toggleListening() async {
        if recognizer.isListening {
            let heard = await recognizer.stop()
            send(heard)
            return
        }
        guard await recognizer.requestPermissions() else {
            errorMessage = SpeechRecognizer.RecognizerError.notAuthorized.localizedDescription
            return
        }
        speaker.stop() // talking over the guide interrupts it
        do {
            try recognizer.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func respond(to text: String) async {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let artwork, let photoJPEG else { return }

        speaker.stop()
        messages.append(ChatMessage(role: .user, text: question))
        let history = messages
        let reply = ChatMessage(role: .assistant, text: "")
        messages.append(reply)
        isResponding = true
        defer { isResponding = false }

        func update(_ change: (inout ChatMessage) -> Void) {
            guard let index = messages.firstIndex(where: { $0.id == reply.id }) else { return }
            change(&messages[index])
        }

        do {
            for try await chunk in client.streamReply(artwork: artwork, imageJPEG: photoJPEG, turns: history) {
                switch chunk {
                case .text(let piece):
                    update { $0.text += piece }
                    if speakReplies { speaker.feed(piece) }
                case .restart:
                    update { $0.text = "" }
                    speaker.stop()
                }
            }
            if speakReplies { speaker.finish() }
        } catch is CancellationError {
            messages.removeAll { $0.id == reply.id }
        } catch {
            // A partial answer that was refused or cut off is not kept as if it were complete.
            messages.removeAll { $0.id == reply.id }
            speaker.stop()
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    // MARK: Export

    var transcript: TranscriptDocument? {
        guard let artwork, messages.contains(where: { !$0.text.isEmpty }) else { return nil }
        return TranscriptDocument(
            filename: TranscriptExporter.filename(for: artwork),
            text: TranscriptExporter.markdown(artwork: artwork, messages: messages)
        )
    }
}
