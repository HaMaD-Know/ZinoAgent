import SwiftUI
import UniformTypeIdentifiers

public struct FileManagerView: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var viewModel: FileManagerViewModel

    @State private var showFolderPicker = false
    @State private var showReconnectPicker = false
    @State private var showImportPicker = false
    @State private var showNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var renamingItem: FileItem?
    @State private var renameText = ""
    @State private var pendingDeleteItems: [FileItem]?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _viewModel = StateObject(wrappedValue: FileManagerViewModel(coordinator: coordinator))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                folderSelectorBar
                Divider()

                if viewModel.mountedFolders.isEmpty {
                    emptyFolderOnboarding
                } else {
                    breadcrumbAndFilterBar
                    Divider()

                    if let status = viewModel.statusMessage {
                        statusStrip(message: status, isError: false) { viewModel.statusMessage = nil }
                    }
                    if let err = viewModel.errorMessage {
                        statusStrip(message: err, isError: true) { viewModel.errorMessage = nil }
                    }
                    if let stale = viewModel.needsReconnectFolder {
                        reconnectBanner(folder: stale)
                    }

                    fileListingContent
                }
            }
            .background(ZinoTheme.surfacePrimary)
            .navigationTitle("Files")
            .searchable(text: $viewModel.searchQuery, prompt: "Search files in selected folder")
            .onChange(of: viewModel.searchQuery) { _, _ in
                viewModel.loadCurrentDirectory()
            }
            .toolbar { toolbarContent }
            .sheet(isPresented: $showFolderPicker) {
                DocumentPickerView(contentTypes: [.folder], allowsMultipleSelection: false) { urls in
                    if let first = urls.first { viewModel.addFolder(from: first) }
                }
            }
            .sheet(isPresented: $showReconnectPicker) {
                DocumentPickerView(contentTypes: [.folder], allowsMultipleSelection: false) { urls in
                    if let first = urls.first, let target = viewModel.needsReconnectFolder ?? viewModel.selectedFolder {
                        viewModel.reconnectFolder(target, with: first)
                    }
                }
            }
            .sheet(isPresented: $showImportPicker) {
                DocumentPickerView(contentTypes: [.item], allowsMultipleSelection: true) { urls in
                    viewModel.importExternalFiles(urls)
                }
            }
            .sheet(item: $viewModel.previewItem) { item in
                if let folder = viewModel.selectedFolder {
                    FilePreviewSheet(
                        item: item,
                        folder: folder,
                        fileService: coordinator.fileService,
                        onAskAI: { viewModel.askAIAbout(item) },
                        onOpen3D: { viewModel.openInThreeDStudio(item) },
                        onExtractZip: { viewModel.extractZip(item) }
                    )
                }
            }
            .sheet(item: $viewModel.infoItem) { item in
                FileInfoSheet(item: item)
            }
            .sheet(isPresented: Binding(
                get: { viewModel.shareURLs != nil },
                set: { if !$0 { viewModel.shareURLs = nil } }
            )) {
                if let urls = viewModel.shareURLs {
                    ShareSheetView(activityItems: urls)
                }
            }
            .alert("New Folder", isPresented: $showNewFolderAlert) {
                TextField("Folder name", text: $newFolderName)
                Button("Create") {
                    viewModel.createNewFolder(named: newFolderName)
                    newFolderName = ""
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
            .alert("Rename Item", isPresented: Binding(
                get: { renamingItem != nil },
                set: { if !$0 { renamingItem = nil } }
            )) {
                TextField("New name", text: $renameText)
                Button("Rename") {
                    if let item = renamingItem {
                        viewModel.renameItem(item, to: renameText)
                    }
                    renamingItem = nil
                }
                Button("Cancel", role: .cancel) { renamingItem = nil }
            }
            .confirmationDialog(
                "Delete Selected Item(s)?",
                isPresented: Binding(
                    get: { pendingDeleteItems != nil },
                    set: { if !$0 { pendingDeleteItems = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Move to Recoverable Trash", role: .destructive) {
                    if let targets = pendingDeleteItems {
                        viewModel.deleteItems(targets)
                    }
                    pendingDeleteItems = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteItems = nil }
            } message: {
                let count = pendingDeleteItems?.count ?? 0
                Text("This will remove \(count) item(s) into recoverable folder trash (.zino_trash). You can restore them with Undo.")
            }
            .onAppear {
                viewModel.reloadFolders()
            }
        }
    }

    // MARK: - Top Bars

    private var folderSelectorBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.mountedFolders) { folder in
                    let isSelected = viewModel.selectedFolder?.id == folder.id
                    Button {
                        viewModel.selectFolder(folder)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: folder.isAccessible ? "folder.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(folder.isAccessible ? (isSelected ? .white : .accentColor) : ZinoTheme.statusWarning)
                            Text(folder.displayName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(isSelected ? Color.accentColor : ZinoTheme.surfaceSecondary)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            viewModel.needsReconnectFolder = folder
                            showReconnectPicker = true
                        } label: {
                            Label("Reconnect Folder", systemImage: "arrow.triangle.2.circlepath")
                        }
                        Button(role: .destructive) {
                            viewModel.removeFolder(folder)
                        } label: {
                            Label("Remove from Workspace", systemImage: "trash")
                        }
                    }
                }

                Button {
                    showFolderPicker = true
                } label: {
                    Label("Add Folder", systemImage: "folder.badge.plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(ZinoTheme.surfaceSecondary)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(ZinoTheme.border, lineWidth: 0.75))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, ZinoTheme.Spacing.md)
            .padding(.vertical, 10)
        }
        .background(ZinoTheme.surfacePrimary)
    }

    private var breadcrumbAndFilterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(viewModel.breadcrumbURLs.enumerated()), id: \.offset) { idx, url in
                            if idx > 0 {
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Button {
                                viewModel.navigateTo(directoryURL: url)
                            } label: {
                                Text(url.lastPathComponent)
                                    .font(.caption.weight(idx == viewModel.breadcrumbURLs.count - 1 ? .semibold : .regular))
                                    .foregroundStyle(idx == viewModel.breadcrumbURLs.count - 1 ? .primary : .secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()

                if viewModel.clipboardItems != nil {
                    Button {
                        viewModel.pasteClipboardHere()
                    } label: {
                        Label("Paste", systemImage: "doc.on.clipboard")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if viewModel.undoCount > 0 {
                    Button {
                        viewModel.undoLastOperation()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(FileCategory.allCases) { category in
                        let selected = viewModel.selectedCategory == category
                        Button {
                            viewModel.selectedCategory = category
                            viewModel.loadCurrentDirectory()
                        } label: {
                            Label(category.displayName, systemImage: category.iconName)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(selected ? Color.accentColor.opacity(0.16) : ZinoTheme.surfaceSecondary)
                                .foregroundStyle(selected ? Color.accentColor : .secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, ZinoTheme.Spacing.md)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    private var emptyFolderOnboarding: some View {
        ContentUnavailableView {
            Label("Select a Folder from Files", systemImage: "folder.badge.plus")
        } description: {
            Text("ZinoAgent respects iPadOS privacy and sandbox rules. Explicitly choose one or more folders from Apple's Files app to browse, manage, and work with them using AI.")
        } actions: {
            Button {
                showFolderPicker = true
            } label: {
                Label("Choose Folder in Files", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var fileListingContent: some View {
        let items = viewModel.visibleItems
        if items.isEmpty {
            ContentUnavailableView(
                viewModel.searchQuery.isEmpty ? "Folder Is Empty" : "No Matching Files",
                systemImage: "doc.text.magnifyingglass",
                description: Text(viewModel.searchQuery.isEmpty ? "Create a folder or import files to get started." : "Try a different search query or filter.")
            )
        } else if viewModel.viewMode == .grid {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 132), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(items) { item in
                        gridCell(item)
                    }
                }
                .padding(ZinoTheme.Spacing.md)
            }
        } else {
            List {
                ForEach(items) { item in
                    listRow(item)
                }
            }
            .listStyle(.plain)
        }
    }

    private func gridCell(_ item: FileItem) -> some View {
        let isSelected = viewModel.selectedItemIDs.contains(item.id)
        return Button {
            handleTap(item)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : ZinoTheme.surfaceSecondary)
                        .frame(height: 82)
                        .overlay(
                            Image(systemName: item.iconName)
                                .font(.system(size: 32))
                                .foregroundStyle(iconTint(for: item))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isSelected ? Color.accentColor : ZinoTheme.border, lineWidth: isSelected ? 2 : 0.75)
                        )

                    if viewModel.isMultiSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .padding(6)
                    } else if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .padding(6)
                    }
                }

                VStack(spacing: 2) {
                    Text(item.name)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(item.isDirectory ? "Folder" : Formatters.bytes(item.sizeBytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu { itemContextMenu(item) }
    }

    private func listRow(_ item: FileItem) -> some View {
        let isSelected = viewModel.selectedItemIDs.contains(item.id)
        return Button {
            handleTap(item)
        } label: {
            HStack(spacing: 12) {
                if viewModel.isMultiSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                Image(systemName: item.iconName)
                    .font(.title3)
                    .foregroundStyle(iconTint(for: item))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if item.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(item.isDirectory ? "Folder" : Formatters.bytes(item.sizeBytes))
                        if let mod = item.modifiedAt {
                            Text("• \(Formatters.relativeDate(mod))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if item.isDirectory {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { itemContextMenu(item) }
    }

    @ViewBuilder
    private func itemContextMenu(_ item: FileItem) -> some View {
        Button { viewModel.openItem(item) } label: { Label(item.isDirectory ? "Open Folder" : "Preview", systemImage: "eye") }
        if !item.isDirectory {
            Button { viewModel.askAIAbout(item) } label: { Label("Ask AI About File", systemImage: "sparkles") }
        }
        if ["html", "htm"].contains(item.fileExtension.lowercased()), let folder = viewModel.selectedFolder {
            Button {
                _ = try? coordinator.browserService.serveAndOpenFile(relativePath: item.name, in: folder)
                coordinator.openChatRightDock(tab: .browser)
            } label: {
                Label("Serve & Open in AI Browser", systemImage: "globe")
            }
        }
        if item.isThreeDModel {
            Button { viewModel.openInThreeDStudio(item) } label: { Label("Open in 3D Studio", systemImage: "cube") }
        }
        if item.fileExtension == "zip" {
            Button { viewModel.extractZip(item) } label: { Label("Extract ZIP", systemImage: "doc.zipper") }
        }
        Divider()
        Button { viewModel.toggleFavorite(item) } label: {
            Label(item.isFavorite ? "Remove Favorite" : "Favorite", systemImage: item.isFavorite ? "star.slash" : "star")
        }
        Button { viewModel.infoItem = item } label: { Label("Get Info", systemImage: "info.circle") }
        Button {
            renamingItem = item
            renameText = item.name
        } label: { Label("Rename", systemImage: "pencil") }
        Button { viewModel.duplicateItem(item) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Button { viewModel.stageClipboard(operation: .copy, targets: [item]) } label: { Label("Copy", systemImage: "doc.on.doc") }
        Button { viewModel.stageClipboard(operation: .move, targets: [item]) } label: { Label("Move", systemImage: "folder.badge.gearshape") }
        if !item.isDirectory {
            Button { viewModel.prepareShare(items: [item]) } label: { Label("Share / Export", systemImage: "square.and.arrow.up") }
        }
        Divider()
        Button(role: .destructive) {
            pendingDeleteItems = [item]
        } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: - Toolbar & Banners

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if viewModel.isMultiSelecting {
                let selected = viewModel.selectedItems
                Button { viewModel.stageClipboard(operation: .copy, targets: selected) } label: { Image(systemName: "doc.on.doc") }
                    .disabled(selected.isEmpty)
                Button { viewModel.stageClipboard(operation: .move, targets: selected) } label: { Image(systemName: "folder") }
                    .disabled(selected.isEmpty)
                Button { viewModel.prepareShare(items: selected) } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(selected.isEmpty)
                Button(role: .destructive) { pendingDeleteItems = selected } label: { Image(systemName: "trash") }
                    .disabled(selected.isEmpty)
                Button("Done") {
                    viewModel.isMultiSelecting = false
                    viewModel.selectedItemIDs.removeAll()
                }
            } else {
                Button {
                    showNewFolderAlert = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .disabled(viewModel.selectedFolder == nil)

                Button {
                    showImportPicker = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .disabled(viewModel.selectedFolder == nil)

                Button {
                    viewModel.isMultiSelecting = true
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .disabled(viewModel.items.isEmpty)

                Menu {
                    Picker("View", selection: $viewModel.viewMode) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(FileViewMode.grid)
                        Label("List", systemImage: "list.bullet").tag(FileViewMode.list)
                    }
                    Divider()
                    Picker("Sort By", selection: $viewModel.sortOption) {
                        ForEach(FileSortOption.allCases) { opt in
                            Text(opt.displayName).tag(opt)
                        }
                    }
                    Button {
                        viewModel.sortAscending.toggle()
                        viewModel.loadCurrentDirectory()
                    } label: {
                        Label(viewModel.sortAscending ? "Descending" : "Ascending", systemImage: "arrow.up.arrow.down")
                    }
                } label: {
                    Label("Display", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private func reconnectBanner(folder: MountedFolder) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(ZinoTheme.statusWarning)
            Text("Permission to '\(folder.displayName)' expired. Reconnect it via Apple Files.")
                .font(.caption)
            Spacer()
            Button("Reconnect") {
                showReconnectPicker = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(ZinoTheme.statusWarning.opacity(0.12))
    }

    private func statusStrip(message: String, isError: Bool, dismissAction: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? ZinoTheme.statusCritical : ZinoTheme.statusPositive)
            Text(message).font(.caption).lineLimit(2)
            Spacer()
            Button(action: dismissAction) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background((isError ? ZinoTheme.statusCritical : ZinoTheme.statusPositive).opacity(0.10))
    }

    private func handleTap(_ item: FileItem) {
        if viewModel.isMultiSelecting {
            if viewModel.selectedItemIDs.contains(item.id) {
                viewModel.selectedItemIDs.remove(item.id)
            } else {
                viewModel.selectedItemIDs.insert(item.id)
            }
        } else {
            viewModel.openItem(item)
        }
    }

    private func iconTint(for item: FileItem) -> Color {
        if item.isDirectory { return .blue }
        switch item.category {
        case .documents: return .orange
        case .images: return .purple
        case .threeD: return .teal
        case .code: return .green
        case .archives: return .brown
        default: return .secondary
        }
    }
}
