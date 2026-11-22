import SwiftUI
import UniformTypeIdentifiers

public struct ThreeDStudioView: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var viewModel: ThreeDStudioViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var showModelImporter = false
    @State private var showCompactInspectorSheet = false

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _viewModel = StateObject(wrappedValue: ThreeDStudioViewModel(coordinator: coordinator))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !coordinator.threeDService.projects.isEmpty {
                    recentProjectsBar
                    Divider()
                }

                if let err = viewModel.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(ZinoTheme.statusCritical)
                        Text(err).font(.caption).lineLimit(3)
                        Spacer()
                        Button { viewModel.errorMessage = nil } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(ZinoTheme.statusCritical.opacity(0.10))
                }

                HStack(spacing: 0) {
                    viewportColumn
                    if horizontalSizeClass == .regular && viewModel.showInspector && viewModel.loadedModel != nil {
                        Divider()
                        inspectorPanel
                            .frame(width: 320)
                    }
                }
            }
            .background(ZinoTheme.surfacePrimary)
            .navigationTitle(viewModel.activeProject?.name ?? "3D Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            .sheet(isPresented: $showModelImporter) {
                DocumentPickerView(contentTypes: [.item], allowsMultipleSelection: false) { urls in
                    if let first = urls.first { viewModel.requestImport(from: first) }
                }
            }
            .sheet(isPresented: $showCompactInspectorSheet) {
                NavigationStack {
                    inspectorPanel
                        .navigationTitle("Model Inspector")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { showCompactInspectorSheet = false }
                            }
                        }
                }
            }
            .alert("Large 3D Model Warning", isPresented: Binding(
                get: { viewModel.largeFileWarning != nil },
                set: { if !$0 { viewModel.largeFileWarning = nil } }
            )) {
                Button("Load Full Quality") {
                    if let w = viewModel.largeFileWarning {
                        viewModel.performImport(from: w.url)
                    }
                }
                Button("Cancel", role: .cancel) { viewModel.largeFileWarning = nil }
            } message: {
                if let w = viewModel.largeFileWarning {
                    Text("'\(w.url.lastPathComponent)' is \(Formatters.bytes(w.fileSizeBytes)) (above your \(w.thresholdMB) MB threshold). ZinoAgent will NOT reduce polygons or textures automatically. Ensure enough RAM is free on your iPad before loading.")
                }
            }
            .onAppear {
                coordinator.threeDService.reloadProjects()
                viewModel.consumePendingHandoff()
            }
        }
    }

    // MARK: - Projects Bar

    private var recentProjectsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(coordinator.threeDService.projects) { project in
                    let isSelected = viewModel.activeProject?.id == project.id
                    Button {
                        viewModel.openProject(project)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cube.fill")
                                .font(.caption)
                            Text(project.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Text(project.format.displayName)
                                .font(.caption2)
                                .opacity(0.75)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isSelected ? Color.accentColor : ZinoTheme.surfaceSecondary)
                        .foregroundStyle(isSelected ? .white : .primary)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            viewModel.deleteProject(project)
                        } label: {
                            Label("Delete Project Copy", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Viewport

    private var viewportColumn: some View {
        ZStack {
            if let loaded = viewModel.loadedModel {
                SceneKitViewportView(
                    loadedModel: loaded,
                    lightingPreset: viewModel.lightingPreset,
                    environmentPreset: viewModel.environmentPreset,
                    lightIntensity: viewModel.lightIntensity,
                    isWireframe: viewModel.isWireframe,
                    showGrid: viewModel.showGrid,
                    resetCameraToken: viewModel.resetCameraToken,
                    selectedNodeID: viewModel.selectedNodeID,
                    onSelectNode: { id in viewModel.selectedNodeID = id }
                )

                VStack {
                    Spacer()
                    viewportControlsBar
                        .padding(12)
                }
            } else {
                ContentUnavailableView {
                    Label("3D Model Studio", systemImage: "cube.transparent")
                } description: {
                    Text("Import GLB, GLTF, USDZ, OBJ, or STL models for interactive Metal-accelerated 3D viewing, object hierarchy navigation, and PBR material inspection without flattening or quality loss.")
                } actions: {
                    Button {
                        showModelImporter = true
                    } label: {
                        Label("Import 3D Model", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if viewModel.isLoading {
                ProgressView("Parsing 3D geometry & textures...")
                    .padding(18)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var viewportControlsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    viewModel.resetCamera()
                } label: {
                    Label("Reset Camera", systemImage: "camera.metering.center.weighted")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Toggle(isOn: $viewModel.isWireframe) {
                    Label("Wireframe", systemImage: "square.grid.3x3")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)

                Toggle(isOn: $viewModel.showGrid) {
                    Label("Grid", systemImage: "grid")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)

                Menu {
                    Picker("Lighting", selection: $viewModel.lightingPreset) {
                        ForEach(ThreeDLightingPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                } label: {
                    Label(viewModel.lightingPreset.displayName, systemImage: "sun.max")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Menu {
                    Picker("Environment", selection: $viewModel.environmentPreset) {
                        ForEach(ThreeDEnvironmentPreset.allCases) { env in
                            Text(env.displayName).tag(env)
                        }
                    }
                } label: {
                    Label(viewModel.environmentPreset.displayName, systemImage: "circle.lefthalf.filled")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                HStack(spacing: 4) {
                    Image(systemName: "light.max").font(.caption2)
                    Slider(value: $viewModel.lightIntensity, in: 0.2...2.5)
                        .frame(width: 85)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    // MARK: - Inspector Panel

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $viewModel.inspectorTab) {
                ForEach(ThreeDStudioViewModel.InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)

            Divider()

            if let meta = viewModel.loadedModel?.metadata {
                switch viewModel.inspectorTab {
                case .hierarchy:
                    hierarchyTab(meta)
                case .materials:
                    materialsTab(meta)
                case .info:
                    infoTab(meta)
                }
            }
        }
        .background(ZinoTheme.surfaceSecondary.opacity(0.4))
    }

    private func hierarchyTab(_ meta: ThreeDModelMetadata) -> some View {
        List {
            if let selected = viewModel.selectedNodeInfo() {
                Section("Selected Transform") {
                    LabeledContent("Object", value: selected.name)
                    LabeledContent("Position", value: selected.position.formatted)
                    LabeledContent("Rotation (°)", value: selected.eulerAnglesDegrees.formatted)
                    LabeledContent("Scale", value: selected.scale.formatted)
                    if selected.hasMesh {
                        LabeledContent("Geometry", value: "\(selected.vertexCount) verts • \(selected.triangleCount) tris")
                    }
                    if !selected.materialNames.isEmpty {
                        LabeledContent("Materials", value: selected.materialNames.joined(separator: ", "))
                    }
                }
            }

            Section("Scene Hierarchy (\(meta.objectCount) objects)") {
                ForEach(flattenHierarchy(meta.rootNodes)) { item in
                    HierarchyNodeRow(
                        node: item.node,
                        depth: item.depth,
                        selectedNodeID: $viewModel.selectedNodeID,
                        hiddenNodeIDs: viewModel.hiddenNodeIDs,
                        onToggleVisibility: { viewModel.toggleNodeVisibility(nodeID: $0) }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func materialsTab(_ meta: ThreeDModelMetadata) -> some View {
        List {
            Section("Materials (\(meta.materials.count))") {
                if meta.materials.isEmpty {
                    Text("Model uses default shading material.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(meta.materials) { mat in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(mat.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(mat.baseColorHex)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text("Metalness: \(String(format: "%.2f", mat.metalness)) • Roughness: \(String(format: "%.2f", mat.roughness)) • \(mat.alphaMode)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if !mat.textureChannels.isEmpty {
                                Text("Maps: \(mat.textureChannels.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section("Textures (\(meta.textures.count))") {
                if meta.textures.isEmpty {
                    Text("No embedded or linked textures detected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(meta.textures) { tex in
                        HStack(spacing: 10) {
                            if let img = tex.previewImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tex.name).font(.caption.weight(.semibold))
                                Text("\(tex.channel) • \(tex.width)×\(tex.height) px")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func infoTab(_ meta: ThreeDModelMetadata) -> some View {
        List {
            Section("Asset Summary") {
                LabeledContent("File", value: meta.fileName)
                LabeledContent("Format", value: meta.format.displayName)
                LabeledContent("File Size", value: Formatters.bytes(meta.fileSizeBytes))
                LabeledContent("Load Time", value: "\(meta.loadDurationMs) ms")
            }
            Section("Geometry & Structure") {
                LabeledContent("Dimensions (W×H×D)", value: String(format: "%.2f × %.2f × %.2f", meta.dimensions.x, meta.dimensions.y, meta.dimensions.z))
                LabeledContent("Objects", value: "\(meta.objectCount)")
                LabeledContent("Meshes", value: "\(meta.meshCount)")
                LabeledContent("Vertices", value: "\(meta.vertexCount)")
                LabeledContent("Triangles", value: "\(meta.triangleCount)")
                LabeledContent("Materials", value: "\(meta.materialCount)")
                LabeledContent("Textures", value: "\(meta.textureCount)")
            }
            Section("Animations") {
                if meta.animationNames.isEmpty {
                    Text("No animation clips found.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(meta.animationNames, id: \.self) { clip in
                        Label(clip, systemImage: "film")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showModelImporter = true
            } label: {
                Label("Import Model", systemImage: "square.and.arrow.down")
            }
            if viewModel.loadedModel != nil {
                Button {
                    viewModel.explainModelWithAI()
                } label: {
                    Label("Explain with AI", systemImage: "sparkles")
                }
                Button {
                    if horizontalSizeClass == .regular {
                        viewModel.showInspector.toggle()
                    } else {
                        showCompactInspectorSheet = true
                    }
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
            }
        }
    }
}

private struct FlattenedHierarchyNode: Identifiable {
    let node: ThreeDNodeInfo
    let depth: Int
    var id: String { node.id }
}

private func flattenHierarchy(_ nodes: [ThreeDNodeInfo], depth: Int = 0) -> [FlattenedHierarchyNode] {
    var out: [FlattenedHierarchyNode] = []
    for node in nodes {
        out.append(FlattenedHierarchyNode(node: node, depth: depth))
        if !node.children.isEmpty {
            out.append(contentsOf: flattenHierarchy(node.children, depth: depth + 1))
        }
    }
    return out
}

private struct HierarchyNodeRow: View {
    let node: ThreeDNodeInfo
    let depth: Int
    @Binding var selectedNodeID: String?
    let hiddenNodeIDs: Set<String>
    let onToggleVisibility: (String) -> Void

    var body: some View {
        let isSelected = selectedNodeID == node.id
        let isHidden = hiddenNodeIDs.contains(node.id)
        HStack(spacing: 6) {
            if depth > 0 {
                Spacer().frame(width: CGFloat(depth * 14))
            }
            Image(systemName: node.hasMesh ? "cube.fill" : "folder")
                .font(.caption)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Button {
                selectedNodeID = node.id
            } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.caption.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isHidden ? .tertiary : .primary)
                        .lineLimit(1)
                    if node.hasMesh {
                        Text("\(node.vertexCount)v • \(node.triangleCount)t")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                onToggleVisibility(node.id)
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.caption)
                    .foregroundStyle(isHidden ? .tertiary : .secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }
}
