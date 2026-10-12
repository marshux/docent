import SwiftUI

/// API key entry and model choice. Shown full-screen until a key exists, then as a sheet.
struct SettingsView: View {
    let isOnboarding: Bool

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var keyDraft = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                SecureField("sk-ant-...", text: $keyDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(model.hasAPIKey ? "Replace key" : "Save key") {
                    model.saveAPIKey(keyDraft)
                    keyDraft = ""
                }
                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                if model.hasAPIKey {
                    Button("Remove key from this device", role: .destructive) { model.deleteAPIKey() }
                }
            } header: {
                Text("Claude API key")
            } footer: {
                Text("""
                \(model.hasAPIKey ? "A key is saved. " : "")Docent uses your own Claude API key, so usage is billed to your \
                Anthropic account. The key is stored in this device's Keychain and sent only to api.anthropic.com. \
                Create one at console.anthropic.com.
                """)
            }

            if model.hasAPIKey {
                Section("Model") {
                    Picker("Model", selection: $model.model) {
                        ForEach(ClaudeModel.allCases) { option in
                            VStack(alignment: .leading) {
                                Text(option.displayName)
                                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Voice") {
                    Toggle("Read answers aloud", isOn: $model.speakReplies)
                }
            }
        }
        .navigationTitle(isOnboarding ? "Welcome to Docent" : "Settings")
        .toolbar {
            if !isOnboarding {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
