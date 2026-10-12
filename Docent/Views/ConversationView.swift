import SwiftUI

/// Step 3: talk with the guide. Tap the mic to ask out loud; answers are spoken and shown as text.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @State private var typedQuestion = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.messages.last?.text) {
                    guard let last = model.messages.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }

            Divider()
            VStack(spacing: 12) {
                if model.recognizer.isListening {
                    Text(model.recognizer.transcript.isEmpty ? "Listening…" : model.recognizer.transcript)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    Task { await model.toggleListening() }
                } label: {
                    Image(systemName: model.recognizer.isListening ? "stop.fill" : "mic.fill")
                        .font(.title)
                        .frame(width: 72, height: 72)
                        .background(model.recognizer.isListening ? Color.red : Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .disabled(model.isResponding && !model.recognizer.isListening)
                .accessibilityLabel(model.recognizer.isListening ? "Stop and send" : "Ask a question")

                HStack {
                    TextField("Or type a question", text: $typedQuestion)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .onSubmit(sendTyped)
                    Button("Send", systemImage: "arrow.up.circle.fill", action: sendTyped)
                        .labelStyle(.iconOnly)
                        .font(.title2)
                        .disabled(typedQuestion.trimmingCharacters(in: .whitespaces).isEmpty || model.isResponding)
                }
            }
            .padding()
        }
        .navigationTitle(model.artwork?.title ?? "Conversation")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(
                    model.speakReplies ? "Mute voice" : "Unmute voice",
                    systemImage: model.speakReplies ? "speaker.wave.2" : "speaker.slash"
                ) {
                    model.speakReplies.toggle()
                }
                if let transcript = model.transcript {
                    ShareLink(item: transcript, preview: SharePreview(transcript.filename)) {
                        Label("Export transcript", systemImage: "square.and.arrow.up")
                    }
                }
                Button("New artwork", systemImage: "camera") { model.startOver() }
            }
        }
    }

    private func sendTyped() {
        let question = typedQuestion
        typedQuestion = ""
        model.send(question)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == .user }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Group {
                if message.text.isEmpty {
                    ProgressView()
                } else {
                    Text(message.text).textSelection(.enabled)
                }
            }
            .padding(12)
            .background(isUser ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}
