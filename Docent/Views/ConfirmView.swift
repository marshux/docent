import SwiftUI

/// Step 2: show what Claude thinks the artwork is and how sure it is; the visitor confirms or corrects it.
struct ConfirmView: View {
    @Environment(AppModel.self) private var model
    @State private var title = ""
    @State private var artist = ""
    @State private var year = ""
    @State private var medium = ""
    /// True once the visitor types over the suggestion or picks an alternative.
    @State private var edited = false

    var body: some View {
        Form {
            if let photo = model.photo {
                Section {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 240)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                }
            }

            if let identification = model.identification {
                Section {
                    ConfidenceBadge(identification: identification)
                    Text(identification.reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Title", text: edits($title))
                    TextField("Artist", text: edits($artist))
                    TextField("Year", text: edits($year))
                    TextField("Medium", text: edits($medium))
                } header: {
                    Text("Artwork")
                } footer: {
                    Text("Correct anything that's wrong. Your guide will go by what's written here.")
                }

                if !identification.alternatives.isEmpty {
                    Section("It could also be") {
                        ForEach(identification.alternatives) { alternative in
                            Button {
                                title = alternative.title
                                artist = alternative.artist
                                year = ""
                                medium = ""
                                edited = true
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(alternative.title)
                                    Text(alternative.artist).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section {
                Button("Start conversation") {
                    model.confirm(Artwork(
                        title: title.trimmingCharacters(in: .whitespaces),
                        artist: artist.trimmingCharacters(in: .whitespaces),
                        year: year.trimmingCharacters(in: .whitespaces),
                        medium: medium.trimmingCharacters(in: .whitespaces),
                        confidence: edited ? nil : model.identification?.confidence
                    ))
                }
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Take a different photo", role: .cancel) { model.startOver() }
            }
        }
        .navigationTitle("Is this right?")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let identification = model.identification else { return }
            title = identification.title
            artist = identification.artist
            year = identification.year
            medium = identification.medium
        }
    }

    /// A binding that also records that the visitor changed the suggested details.
    private func edits(_ binding: Binding<String>) -> Binding<String> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                if newValue != binding.wrappedValue { edited = true }
                binding.wrappedValue = newValue
            }
        )
    }
}

private struct ConfidenceBadge: View {
    let identification: ArtworkIdentification

    private var label: String {
        guard identification.identified else { return "Not identified" }
        return switch identification.confidence {
        case .high: "Confident match"
        case .medium: "Likely match"
        case .low: "Best guess"
        }
    }

    private var symbol: String {
        guard identification.identified else { return "questionmark.circle" }
        return switch identification.confidence {
        case .high: "checkmark.seal.fill"
        case .medium: "checkmark.circle"
        case .low: "questionmark.circle"
        }
    }

    private var color: Color {
        guard identification.identified else { return .orange }
        return switch identification.confidence {
        case .high: .green
        case .medium: .yellow
        case .low: .orange
        }
    }

    var body: some View {
        Label(label, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(color)
    }
}
