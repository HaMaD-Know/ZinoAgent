import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native Apple Files document picker supporting folder selection (with security-scoped access)
/// and arbitrary file imports.
public struct DocumentPickerView: UIViewControllerRepresentable {
    public let contentTypes: [UTType]
    public let allowsMultipleSelection: Bool
    public let onPick: ([URL]) -> Void

    public init(
        contentTypes: [UTType],
        allowsMultipleSelection: Bool = false,
        onPick: @escaping ([URL]) -> Void
    ) {
        self.contentTypes = contentTypes
        self.allowsMultipleSelection = allowsMultipleSelection
        self.onPick = onPick
    }

    public func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: false)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    public func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    public final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }

        public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
    }
}

/// Native iOS/iPadOS Share Sheet (`UIActivityViewController`) wrapper for exporting files, conversations, and images.
public struct ShareSheetView: UIViewControllerRepresentable {
    public let activityItems: [Any]

    public init(activityItems: [Any]) {
        self.activityItems = activityItems
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
