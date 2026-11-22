import SwiftUI
import PDFKit
import UIKit

public struct FilePreviewSheet: View {
    public let item: FileItem
    public let folder: MountedFolder
    public let fileService: FileManagerService
    public let onAskAI: () -> Void
    public let onOpen3D: () -> Void
    public let onExtractZip: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var loadedText: String?
    @State private var loadedImage: UIImage?
    @State private var pdfDocument: PDFDocument?
    @State private var zipEntries: [ZipArchiveEntry]?
    @State private var loadError: String?
    @State private var isLoading = true

    public var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading preview...")
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Preview Unavailable", systemImage: "doc.questionmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        if item.isThreeDModel {
                            Button("Open in 3D Studio", action: { dismiss(); onOpen3D() })
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else if let pdfDocument {
                    PDFKitView(document: pdfDocument)
                } else if let loadedImage {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: loadedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                } else if let zipEntries {
                    List {
                        Section("Archive Contents (\(zipEntries.count) entries)") {
                            ForEach(zipEntries) { entry in
                                HStack {
                                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                                        .foregroundStyle(.secondary)
                                    Text(entry.path)
                                        .font(.system(.callout, design: .monospaced))
                                    Spacer()
                                    if !entry.isDirectory {
                                        Text(Formatters.bytes(Int64(entry.uncompressedSize)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } else if let loadedText {
                    ScrollView {
                        Text(loadedText)
                            .font(item.category == .code ? .system(.callout, design: .monospaced) : .body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                } else {
                    ContentUnavailableView(
                        "Unsupported Format",
                        systemImage: "doc",
                        description: Text("'\(item.name)' (.\(item.fileExtension)) cannot be previewed directly, but you can share or export it.")
                    )
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if item.fileExtension == "zip" {
                        Button("Extract") {
                            dismiss()
                            onExtractZip()
                        }
                    }
                    if item.isThreeDModel {
                        Button {
                            dismiss()
                            onOpen3D()
                        } label: {
                            Label("Open in 3D Studio", systemImage: "cube")
                        }
                    }
                    Button {
                        dismiss()
                        onAskAI()
                    } label: {
                        Label("Ask AI", systemImage: "sparkles")
                    }
                }
            }
            .task {
                loadPreview()
            }
        }
    }

    private func loadPreview() {
        isLoading = true
        defer { isLoading = false }
        do {
            try fileService.bookmarks.withScopedAccess(for: folder) { root in
                let safeURL = try SecurityScopedBookmarkManager.ensureInsideScope(candidate: item.url, root: root)
                if item.fileExtension == "pdf" {
                    if let doc = PDFDocument(url: safeURL) {
                        pdfDocument = doc
                    } else {
                        loadError = "PDF file could not be rendered."
                    }
                } else if item.isImage {
                    let data = try Data(contentsOf: safeURL)
                    if let img = UIImage(data: data) {
                        loadedImage = img
                    } else {
                        loadError = "Image format could not be decoded."
                    }
                } else if item.fileExtension == "zip" {
                    zipEntries = try DocumentTextExtractor.listZipContents(at: safeURL)
                } else if item.isThreeDModel {
                    loadError = "3D models open interactively in 3D Studio with full orbit camera, lighting, materials, and hierarchy."
                } else if item.isTextReadable {
                    let doc = try DocumentTextExtractor.extract(from: safeURL, maxCharacters: 120_000)
                    loadedText = doc.text
                } else {
                    loadError = "Format '.\(item.fileExtension)' is not previewable as text or media."
                }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }
}

public struct PDFKitView: UIViewRepresentable {
    public let document: PDFDocument

    public func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        return view
    }

    public func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document !== document {
            uiView.document = document
        }
    }
}

public struct FileInfoSheet: View {
    public let item: FileItem
    @Environment(\.dismiss) private var dismiss

    public var body: some View {
        NavigationStack {
            List {
                Section("General") {
                    LabeledContent("Name", value: item.name)
                    LabeledContent("Category", value: item.category.displayName)
                    LabeledContent("Type", value: item.isDirectory ? "Folder" : (item.fileExtension.isEmpty ? "File" : item.fileExtension.uppercased()))
                    LabeledContent("MIME Type", value: item.mimeType)
                    LabeledContent("Size", value: "\(Formatters.bytes(item.sizeBytes)) (\(item.sizeBytes) bytes)")
                }
                Section("Dates & Location") {
                    if let created = item.createdAt {
                        LabeledContent("Created", value: Formatters.timestamp(created))
                    }
                    if let modified = item.modifiedAt {
                        LabeledContent("Modified", value: Formatters.timestamp(modified))
                    }
                    LabeledContent("UTType", value: item.contentTypeIdentifier)
                    LabeledContent("Path", value: item.url.path)
                }
            }
            .navigationTitle("File Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
