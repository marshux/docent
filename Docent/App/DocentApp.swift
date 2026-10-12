import SwiftUI

@main
struct DocentApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if !model.hasAPIKey {
                    SettingsView(isOnboarding: true)
                } else {
                    switch model.phase {
                    case .capture: CaptureView()
                    case .confirm: ConfirmView()
                    case .conversation: ConversationView()
                    }
                }
            }
            .toolbar {
                if model.hasAPIKey {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationStack { SettingsView(isOnboarding: false) }
        }
        .alert("Something went wrong", isPresented: errorIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}
