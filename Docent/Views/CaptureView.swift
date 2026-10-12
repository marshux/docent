import PhotosUI
import SwiftUI
import UIKit

/// Step 1: photograph (or pick a photo of) the artwork, optionally typing its title.
struct CaptureView: View {
    @Environment(AppModel.self) private var model
    @State private var titleHint = ""
    @State private var showingCamera = false
    @State private var pickedItem: PhotosPickerItem?

    private var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "photo.artframe")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("Take a photo of the artwork and ask your guide about it.")
                .font(.title3)
                .multilineTextAlignment(.center)

            TextField("Title, if you know it (optional)", text: $titleHint)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)

            if model.isIdentifying {
                ProgressView("Identifying the artwork…")
            } else {
                VStack(spacing: 12) {
                    if cameraAvailable {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Take photo", systemImage: "camera").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Label("Choose from library", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            Spacer()
            Text("Tip: include the wall label in the frame for a more certain match.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .navigationTitle("Docent")
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { image in
                Task { await model.identify(image, titleHint: titleHint) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    await model.identify(image, titleHint: titleHint)
                } else {
                    model.errorMessage = "Couldn't load that photo. Try another one."
                }
            }
        }
    }
}

/// The system camera, wrapped for SwiftUI.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
