import Foundation
import UIKit
import SceneKit
import SceneKit.ModelIO
import ModelIO
import Combine

/// Asynchronous 3D model loader and project manager supporting GLB, GLTF, USDZ, OBJ, and STL.
/// Preserves original source assets, full object hierarchies, materials, and textures without automatic decimation.
@MainActor
public final class ThreeDService: ObservableObject {
    @Published public private(set) var projects: [ThreeDProjectRecord] = []

    private let database: AppDatabase
    private let storagePaths: AppStoragePaths

    public init(database: AppDatabase, storagePaths: AppStoragePaths) {
        self.database = database
        self.storagePaths = storagePaths
        reloadProjects()
    }

    public func reloadProjects() {
        do {
            let rows = try database.sqlite.query("SELECT * FROM threed_projects ORDER BY last_opened_at DESC;")
            self.projects = rows.compactMap { row in
                guard let id = row.string("id"),
                      let name = row.string("name"),
                      let formatRaw = row.string("format"),
                      let format = ThreeDFormat(rawValue: formatRaw),
                      let relPath = row.string("relative_file_path"),
                      let size = row.int64("file_size_bytes"),
                      let objs = row.int("object_count"),
                      let meshes = row.int("mesh_count"),
                      let mats = row.int("material_count"),
                      let verts = row.int("vertex_count"),
                      let opened = row.date("last_opened_at"),
                      let created = row.date("created_at") else { return nil }
                return ThreeDProjectRecord(
                    id: id,
                    name: name,
                    format: format,
                    relativeFilePath: relPath,
                    originalPath: row.string("original_path"),
                    fileSizeBytes: size,
                    objectCount: objs,
                    meshCount: meshes,
                    materialCount: mats,
                    vertexCount: verts,
                    lastOpenedAt: opened,
                    createdAt: created
                )
            }
        } catch {
            AppLogger.shared.error("ThreeD", "Failed to load 3D projects: \(error.localizedDescription)")
        }
    }

    public func projectFileURL(for project: ThreeDProjectRecord) -> URL {
        storagePaths.threeDProjectsDirectory.appendingPathComponent(project.relativeFilePath)
    }

    /// Imports a 3D model into app-managed `ThreeDProjects/` (preserving the original file intact) and parses it asynchronously.
    public func importAndLoad(from externalURL: URL) async throws -> (model: LoadedThreeDModel, project: ThreeDProjectRecord) {
        let accessed = externalURL.startAccessingSecurityScopedResource()
        defer { if accessed { externalURL.stopAccessingSecurityScopedResource() } }

        guard let format = ThreeDFormat.from(url: externalURL) else {
            throw ZinoError(.unsupportedFormat, "Unsupported 3D format '.\(externalURL.pathExtension)'. Supported formats: GLB, GLTF, USDZ, OBJ, STL.")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: storagePaths.threeDProjectsDirectory, withIntermediateDirectories: true)

        let projectID = UUID().uuidString
        let projectDir = storagePaths.threeDProjectsDirectory.appendingPathComponent(projectID, isDirectory: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let destURL = projectDir.appendingPathComponent(externalURL.lastPathComponent)
        try fm.copyItem(at: externalURL, to: destURL)

        // If OBJ or GLTF has sibling materials/textures in the same folder, best-effort copy them too.
        if format == .obj || format == .gltf {
            let parent = externalURL.deletingLastPathComponent()
            if let siblings = try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                for sibling in siblings where sibling != externalURL {
                    let ext = sibling.pathExtension.lowercased()
                    if ["mtl", "bin", "png", "jpg", "jpeg", "webp"].contains(ext) {
                        let sibDest = projectDir.appendingPathComponent(sibling.lastPathComponent)
                        try? fm.copyItem(at: sibling, to: sibDest)
                    }
                }
            }
        }

        let loaded = try await Self.loadModelFile(at: destURL)
        let relPath = "\(projectID)/\(externalURL.lastPathComponent)"
        let now = Date()
        let record = ThreeDProjectRecord(
            id: projectID,
            name: externalURL.deletingPathExtension().lastPathComponent,
            format: format,
            relativeFilePath: relPath,
            originalPath: externalURL.path,
            fileSizeBytes: loaded.metadata.fileSizeBytes,
            objectCount: loaded.metadata.objectCount,
            meshCount: loaded.metadata.meshCount,
            materialCount: loaded.metadata.materialCount,
            vertexCount: loaded.metadata.vertexCount,
            lastOpenedAt: now,
            createdAt: now
        )

        try persist(record)
        try? database.recordRecentActivity(
            kind: "3d",
            title: record.name,
            subtitle: "\(format.displayName) • \(loaded.metadata.meshCount) meshes • \(Formatters.bytes(record.fileSizeBytes))",
            referenceID: record.id
        )
        reloadProjects()
        return (loaded, record)
    }

    public func openProject(_ project: ThreeDProjectRecord) async throws -> LoadedThreeDModel {
        let url = projectFileURL(for: project)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ZinoError(.fileNotFound, "3D project file '\(project.name)' is missing.")
        }
        let loaded = try await Self.loadModelFile(at: url)
        try? database.sqlite.execute(
            "UPDATE threed_projects SET last_opened_at = ? WHERE id = ?;",
            bindings: [.real(Date().timeIntervalSince1970), .text(project.id)]
        )
        try? database.recordRecentActivity(
            kind: "3d",
            title: project.name,
            subtitle: "\(project.format.displayName) • \(loaded.metadata.meshCount) meshes",
            referenceID: project.id
        )
        reloadProjects()
        return loaded
    }

    public func deleteProject(_ project: ThreeDProjectRecord) throws {
        let fileURL = projectFileURL(for: project)
        let projectDir = fileURL.deletingLastPathComponent()
        if projectDir.lastPathComponent == project.id && FileManager.default.fileExists(atPath: projectDir.path) {
            try FileManager.default.removeItem(at: projectDir)
        }
        try database.sqlite.execute("DELETE FROM threed_projects WHERE id = ?;", bindings: [.text(project.id)])
        try database.sqlite.execute("DELETE FROM recent_activity WHERE reference_id = ? AND kind = '3d';", bindings: [.text(project.id)])
        reloadProjects()
    }

    // MARK: - Asynchronous Multi-Format Loader

    public nonisolated static func loadModelFile(at url: URL) async throws -> LoadedThreeDModel {
        guard let format = ThreeDFormat.from(url: url) else {
            throw ZinoError(.unsupportedFormat, "Unsupported 3D file extension '.\(url.pathExtension)'.")
        }
        return try await Task.detached(priority: .userInitiated) {
            switch format {
            case .glb, .gltf:
                return try GLTF2Parser.parse(fileURL: url)
            case .usdz, .obj, .stl:
                return try loadWithModelIO(url: url, format: format)
            }
        }.value
    }

    private nonisolated static func loadWithModelIO(url: URL, format: ThreeDFormat) throws -> LoadedThreeDModel {
        let started = Date()
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? Int64) ?? 0

        let asset = MDLAsset(url: url)
        asset.loadTextures()

        let rawScene: SCNScene
        if asset.count > 0 {
            rawScene = SCNScene(mdlAsset: asset)
        } else if let direct = try? SCNScene(url: url, options: [.checkConsistency: true]) {
            rawScene = direct
        } else {
            throw ZinoError(.unsupportedFormat, "Could not parse \(format.displayName) model '\(url.lastPathComponent)'.")
        }

        let scene = SCNScene()
        let modelRoot = SCNNode()
        modelRoot.name = "ModelRoot"
        for child in rawScene.rootNode.childNodes {
            child.removeFromParentNode()
            modelRoot.addChildNode(child)
        }
        scene.rootNode.addChildNode(modelRoot)

        // Inspect full SCNNode hierarchy without flattening.
        var nodeMap: [String: SCNNode] = [:]
        var materialInfos: [ThreeDMaterialInfo] = []
        var seenMaterials = Set<String>()
        var textureInfos: [ThreeDTextureInfo] = []
        var totalVertices = 0
        var totalTriangles = 0
        var meshCount = 0
        var objectCount = 0
        var counter = 0

        func inspectNode(_ node: SCNNode) -> ThreeDNodeInfo {
            counter += 1
            let id = "mdl_node_\(counter)"
            let displayName = (node.name?.isEmpty == false) ? node.name! : "Object_\(counter)"
            node.name = id
            nodeMap[id] = node
            objectCount += 1

            var verts = 0
            var tris = 0
            var matNames: [String] = []
            if let geom = node.geometry {
                meshCount += 1
                if let vSource = geom.sources(for: .vertex).first {
                    verts = vSource.vectorCount
                }
                for elem in geom.elements {
                    if elem.primitiveType == .triangles || elem.primitiveType == .triangleStrip {
                        tris += elem.primitiveCount
                    }
                }
                for (mIdx, mat) in geom.materials.enumerated() {
                    let mName = (mat.name?.isEmpty == false) ? mat.name! : "Material_\(mIdx + 1)"
                    matNames.append(mName)
                    if !seenMaterials.contains(mName) {
                        seenMaterials.insert(mName)
                        var channels: [String] = []
                        var hex = "#CCCCCC"
                        if let col = mat.diffuse.contents as? UIColor {
                            hex = colorToHex(col)
                        } else if let img = mat.diffuse.contents as? UIImage {
                            channels.append("Diffuse")
                            textureInfos.append(ThreeDTextureInfo(
                                id: "\(mName)-diffuse",
                                name: "\(mName) Diffuse",
                                channel: "Diffuse",
                                width: Int(img.size.width * img.scale),
                                height: Int(img.size.height * img.scale),
                                previewImage: img
                            ))
                        }
                        if let normImg = mat.normal.contents as? UIImage {
                            channels.append("Normal")
                            textureInfos.append(ThreeDTextureInfo(
                                id: "\(mName)-normal",
                                name: "\(mName) Normal",
                                channel: "Normal",
                                width: Int(normImg.size.width * normImg.scale),
                                height: Int(normImg.size.height * normImg.scale),
                                previewImage: normImg
                            ))
                        }
                        let metalVal = (mat.metalness.contents as? NSNumber)?.floatValue ?? 0.0
                        let roughVal = (mat.roughness.contents as? NSNumber)?.floatValue ?? 0.5
                        materialInfos.append(ThreeDMaterialInfo(
                            id: mName,
                            name: mName,
                            baseColorHex: hex,
                            metalness: metalVal,
                            roughness: roughVal,
                            isDoubleSided: mat.isDoubleSided,
                            alphaMode: mat.transparency < 0.99 ? "BLEND" : "OPAQUE",
                            textureChannels: channels
                        ))
                    }
                }
            }

            totalVertices += verts
            totalTriangles += tris

            let children = node.childNodes.map { inspectNode($0) }
            let radToDeg: Float = 180.0 / .pi
            return ThreeDNodeInfo(
                id: id,
                name: displayName,
                position: ThreeDVector3(x: node.position.x, y: node.position.y, z: node.position.z),
                eulerAnglesDegrees: ThreeDVector3(
                    x: node.eulerAngles.x * radToDeg,
                    y: node.eulerAngles.y * radToDeg,
                    z: node.eulerAngles.z * radToDeg
                ),
                scale: ThreeDVector3(x: node.scale.x, y: node.scale.y, z: node.scale.z),
                hasMesh: node.geometry != nil,
                vertexCount: verts,
                triangleCount: tris,
                materialNames: matNames,
                isHidden: node.isHidden,
                children: children
            )
        }

        let rootInfos = modelRoot.childNodes.map { inspectNode($0) }
        let (minB, maxB) = modelRoot.boundingBox
        let dims = ThreeDVector3(
            x: max(0, maxB.x - minB.x),
            y: max(0, maxB.y - minB.y),
            z: max(0, maxB.z - minB.z)
        )

        var animNames: [String] = []
        modelRoot.enumerateChildNodes { node, _ in
            for key in node.animationKeys where !animNames.contains(key) {
                animNames.append(key)
            }
        }

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let metadata = ThreeDModelMetadata(
            format: format,
            fileName: url.lastPathComponent,
            fileSizeBytes: fileSize,
            dimensions: dims,
            objectCount: objectCount,
            meshCount: meshCount,
            materialCount: materialInfos.count,
            textureCount: textureInfos.count,
            vertexCount: totalVertices,
            triangleCount: totalTriangles,
            animationNames: animNames,
            loadDurationMs: elapsedMs,
            rootNodes: rootInfos,
            materials: materialInfos,
            textures: textureInfos
        )

        return LoadedThreeDModel(
            scene: scene,
            modelRootNode: modelRoot,
            metadata: metadata,
            nodeMap: nodeMap
        )
    }

    private nonisolated static func colorToHex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private func persist(_ p: ThreeDProjectRecord) throws {
        try database.sqlite.execute(
            """
            INSERT INTO threed_projects (
                id, name, format, relative_file_path, original_path, file_size_bytes,
                object_count, mesh_count, material_count, vertex_count, last_opened_at, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                last_opened_at = excluded.last_opened_at;
            """,
            bindings: [
                .text(p.id), .text(p.name), .text(p.format.rawValue), .text(p.relativeFilePath),
                p.originalPath.map { .text($0) } ?? .null,
                .integer(p.fileSizeBytes), .integer(Int64(p.objectCount)), .integer(Int64(p.meshCount)),
                .integer(Int64(p.materialCount)), .integer(Int64(p.vertexCount)),
                .real(p.lastOpenedAt.timeIntervalSince1970), .real(p.createdAt.timeIntervalSince1970)
            ]
        )
    }
}
