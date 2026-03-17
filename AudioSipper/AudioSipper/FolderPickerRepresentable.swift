import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
/// Wraps `UIDocumentPickerViewController` configured for folder selection.
/// The picked URL is security-scoped; callers must balance
/// `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
struct FolderPickerRepresentable: UIViewControllerRepresentable {

    let onFolderPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFolderPicked: onFolderPicked)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIDocumentPickerDelegate {

        private let onFolderPicked: (URL) -> Void

        init(onFolderPicked: @escaping (URL) -> Void) {
            self.onFolderPicked = onFolderPicked
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onFolderPicked(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // No action needed — sheet dismisses automatically.
        }
    }
}
#endif
