import Foundation
import UIKit
import SceneKit

/// Native Swift glTF 2.0 & GLB binary parser that preserves full object hierarchy, local transforms,
/// PBR materials, embedded/external textures, vertex/triangle counts, and animation clip metadata.
public enum GLTF2Parser {
    private static let glbMagic: UInt32 = 0x46546C67 // "glTF"
    private static let chunkJSON: UInt32 = 0x4E4F534A // "JSON"
    private static let chunkBIN: UInt32 = 0x004E4942  // "BIN\0"

    public static func parse(fileURL: URL) throws -> LoadedThreeDModel {
        let started = Date()
        let data = try Data(contentsOf: fileURL)
        let format: ThreeDFormat = fileURL.pathExtension.lowercased() == "gltf" ? .gltf : .glb
        return try parse(
            data: data,
            format: format,
            fileName: fileURL.lastPathComponent,
            baseDirectory: fileURL.deletingLastPathComponent(),
            started: started
        )
    }

    public static func parse(
        data: Data,
        format: ThreeDFormat,
        fileName: String,
        baseDirectory: URL? = nil,
        started: Date = Date()
    ) throws -> LoadedThreeDModel {
        let jsonData: Data
        let embeddedBin: Data?

        if format == .glb {
            let extracted = try extractGLBChunks(data: data)
            jsonData = extracted.json
            embeddedBin = extracted.bin
        } else {
            jsonData = data
            embeddedBin = nil
        }

        let doc: GLTFDocument
        do {
            doc = try JSONDecoder().decode(GLTFDocument.self, from: jsonData)
        } catch {
            throw ZinoError(.unsupportedFormat, "Invalid glTF 2.0 JSON in '\(fileName)': \(error.localizedDescription)")
        }

        // Load all buffers (embedded BIN, base64 data URIs, or external .bin files).
        let buffers = try loadBuffers(doc: doc, embeddedBin: embeddedBin, baseDirectory: baseDirectory)

        // Decode images/textures.
        var decodedImages: [Int: UIImage] = [:]
        if let images = doc.images {
            for (idx, img) in images.enumerated() {
                if let uiImage = decodeImage(img, doc: doc, buffers: buffers, baseDirectory: baseDirectory) {
                    decodedImages[idx] = uiImage
                }
            }
        }

        // Build PBR SCNMaterials + metadata.
        var scnMaterials: [SCNMaterial] = []
        var materialInfos: [ThreeDMaterialInfo] = []
        var textureInfos: [ThreeDTextureInfo] = []

        if let materials = doc.materials {
            for (idx, mat) in materials.enumerated() {
                let built = buildMaterial(
                    mat,
                    index: idx,
                    doc: doc,
                    images: decodedImages,
                    textureInfos: &textureInfos
                )
                scnMaterials.append(built.material)
                materialInfos.append(built.info)
            }
        }

        // Build SCNNode hierarchy without flattening.
        let scene = SCNScene()
        let modelRoot = SCNNode()
        modelRoot.name = "ModelRoot"
        scene.rootNode.addChildNode(modelRoot)

        var nodeMap: [String: SCNNode] = [:]
        var totalVertices = 0
        var totalTriangles = 0
        var meshCount = 0
        var objectCount = 0

        let defaultSceneIdx = doc.scene ?? 0
        let rootNodeIndices: [Int]
        if let scenes = doc.scenes, defaultSceneIdx < scenes.count, let nodes = scenes[defaultSceneIdx].nodes {
            rootNodeIndices = nodes
        } else if let allNodes = doc.nodes {
            let childSet = Set(allNodes.flatMap { $0.children ?? [] })
            rootNodeIndices = allNodes.indices.filter { !childSet.contains($0) }
        } else {
            rootNodeIndices = []
        }

        var rootInfos: [ThreeDNodeInfo] = []
        for nodeIndex in rootNodeIndices {
            let built = buildNodeRecursive(
                index: nodeIndex,
                doc: doc,
                buffers: buffers,
                materials: scnMaterials,
                nodeMap: &nodeMap,
                totalVertices: &totalVertices,
                totalTriangles: &totalTriangles,
                meshCount: &meshCount,
                objectCount: &objectCount
            )
            modelRoot.addChildNode(built.scnNode)
            rootInfos.append(built.info)
        }

        let (minB, maxB) = modelRoot.boundingBox
        let dims = ThreeDVector3(
            x: max(0, maxB.x - minB.x),
            y: max(0, maxB.y - minB.y),
            z: max(0, maxB.z - minB.z)
        )

        let animationNames: [String] = (doc.animations ?? []).enumerated().map { idx, anim in
            anim.name?.isEmpty == false ? anim.name! : "Animation \(idx + 1)"
        }

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let metadata = ThreeDModelMetadata(
            format: format,
            fileName: fileName,
            fileSizeBytes: Int64(data.count),
            dimensions: dims,
            objectCount: objectCount,
            meshCount: meshCount,
            materialCount: max(materialInfos.count, meshCount > 0 ? 1 : 0),
            textureCount: textureInfos.count,
            vertexCount: totalVertices,
            triangleCount: totalTriangles,
            animationNames: animationNames,
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

    // MARK: - GLB Chunk Extraction

    private static func extractGLBChunks(data: Data) throws -> (json: Data, bin: Data?) {
        guard data.count >= 20 else {
            throw ZinoError(.unsupportedFormat, "GLB file is truncated (smaller than 20 bytes).")
        }
        let magic = readUInt32LE(data, at: 0)
        let version = readUInt32LE(data, at: 4)
        guard magic == glbMagic else {
            throw ZinoError(.unsupportedFormat, "Invalid GLB magic header.")
        }
        guard version == 2 else {
            throw ZinoError(.unsupportedFormat, "Unsupported glTF binary version \(version). Only glTF 2.0 is supported.")
        }

        var offset = 12
        var jsonData: Data?
        var binData: Data?

        while offset + 8 <= data.count {
            let chunkLen = Int(readUInt32LE(data, at: offset))
            let chunkType = readUInt32LE(data, at: offset + 4)
            offset += 8
            guard chunkLen >= 0, offset + chunkLen <= data.count else { break }
            let slice = data.subdata(in: offset..<(offset + chunkLen))
            if chunkType == chunkJSON {
                jsonData = slice
            } else if chunkType == chunkBIN {
                binData = slice
            }
            offset += chunkLen
        }

        guard let json = jsonData else {
            throw ZinoError(.unsupportedFormat, "GLB file is missing its JSON scene chunk.")
        }
        return (json, binData)
    }

    // MARK: - Buffers & Images

    private static func loadBuffers(doc: GLTFDocument, embeddedBin: Data?, baseDirectory: URL?) throws -> [Data] {
        guard let defs = doc.buffers else {
            return embeddedBin.map { [$0] } ?? []
        }
        var out: [Data] = []
        for (idx, def) in defs.enumerated() {
            if let uri = def.uri {
                if uri.hasPrefix("data:") {
                    if let comma = uri.firstIndex(of: ",") {
                        let b64 = String(uri[uri.index(after: comma)...])
                        if let decoded = Data(base64Encoded: b64) {
                            out.append(decoded)
                            continue
                        }
                    }
                    throw ZinoError(.unsupportedFormat, "Invalid base64 buffer URI in glTF.")
                } else if let base = baseDirectory {
                    let extURL = base.appendingPathComponent(uri)
                    let extData = try Data(contentsOf: extURL)
                    out.append(extData)
                } else {
                    throw ZinoError(.fileNotFound, "External glTF buffer '\(uri)' could not be located.")
                }
            } else if idx == 0, let bin = embeddedBin {
                out.append(bin)
            } else {
                out.append(Data(count: def.byteLength))
            }
        }
        return out
    }

    private static func decodeImage(_ img: GLTFImage, doc: GLTFDocument, buffers: [Data], baseDirectory: URL?) -> UIImage? {
        if let bvIdx = img.bufferView, let views = doc.bufferViews, bvIdx < views.count {
            let bv = views[bvIdx]
            guard bv.buffer < buffers.count else { return nil }
            let buf = buffers[bv.buffer]
            let start = bv.byteOffset ?? 0
            let end = start + bv.byteLength
            guard start >= 0, end <= buf.count else { return nil }
            return UIImage(data: buf.subdata(in: start..<end))
        }
        if let uri = img.uri {
            if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") {
                let b64 = String(uri[uri.index(after: comma)...])
                if let data = Data(base64Encoded: b64) { return UIImage(data: data) }
            } else if let base = baseDirectory {
                let url = base.appendingPathComponent(uri)
                if let data = try? Data(contentsOf: url) { return UIImage(data: data) }
            }
        }
        return nil
    }

    // MARK: - Materials

    private static func buildMaterial(
        _ mat: GLTFMaterial,
        index: Int,
        doc: GLTFDocument,
        images: [Int: UIImage],
        textureInfos: inout [ThreeDTextureInfo]
    ) -> (material: SCNMaterial, info: ThreeDMaterialInfo) {
        let name = (mat.name?.isEmpty == false) ? mat.name! : "Material_\(index + 1)"
        let scnMat = SCNMaterial()
        scnMat.name = name
        scnMat.lightingModel = .physicallyBased
        scnMat.isDoubleSided = mat.doubleSided ?? false

        var channels: [String] = []
        let pbr = mat.pbrMetallicRoughness

        let factor = pbr?.baseColorFactor ?? [1.0, 1.0, 1.0, 1.0]
        let r = CGFloat(factor.count > 0 ? factor[0] : 1.0)
        let g = CGFloat(factor.count > 1 ? factor[1] : 1.0)
        let b = CGFloat(factor.count > 2 ? factor[2] : 1.0)
        let a = CGFloat(factor.count > 3 ? factor[3] : 1.0)
        let baseColor = UIColor(red: r, green: g, blue: b, alpha: a)

        func textureImage(for texIndex: Int?, channel: String) -> UIImage? {
            guard let tIdx = texIndex, let textures = doc.textures, tIdx < textures.count,
                  let srcIdx = textures[tIdx].source, let img = images[srcIdx] else { return nil }
            channels.append(channel)
            let tName = textures[tIdx].name ?? doc.images?[srcIdx].name ?? "Texture_\(srcIdx + 1)"
            textureInfos.append(ThreeDTextureInfo(
                id: "\(index)-\(channel)-\(srcIdx)",
                name: tName,
                channel: channel,
                width: Int(img.size.width * img.scale),
                height: Int(img.size.height * img.scale),
                previewImage: img
            ))
            return img
        }

        if let baseImg = textureImage(for: pbr?.baseColorTexture?.index, channel: "Base Color") {
            scnMat.diffuse.contents = baseImg
            scnMat.diffuse.wrapS = .repeat
            scnMat.diffuse.wrapT = .repeat
        } else {
            scnMat.diffuse.contents = baseColor
        }

        let metalness = pbr?.metallicFactor ?? 1.0
        let roughness = pbr?.roughnessFactor ?? 1.0
        if let mrImg = textureImage(for: pbr?.metallicRoughnessTexture?.index, channel: "Metallic-Roughness") {
            // glTF stores metallic in Blue channel, roughness in Green channel.
            scnMat.metalness.contents = mrImg
            scnMat.metalness.mappingChannel = 0
            scnMat.roughness.contents = mrImg
            scnMat.roughness.mappingChannel = 0
        } else {
            scnMat.metalness.contents = NSNumber(value: metalness)
            scnMat.roughness.contents = NSNumber(value: roughness)
        }

        if let normalImg = textureImage(for: mat.normalTexture?.index, channel: "Normal") {
            scnMat.normal.contents = normalImg
        }

        if let emissiveImg = textureImage(for: mat.emissiveTexture?.index, channel: "Emissive") {
            scnMat.emission.contents = emissiveImg
        } else if let ef = mat.emissiveFactor, ef.count >= 3, (ef[0] + ef[1] + ef[2]) > 0 {
            scnMat.emission.contents = UIColor(red: CGFloat(ef[0]), green: CGFloat(ef[1]), blue: CGFloat(ef[2]), alpha: 1.0)
        }

        let alphaMode = mat.alphaMode ?? "OPAQUE"
        if alphaMode == "BLEND" {
            scnMat.transparencyMode = .aOne
            scnMat.transparency = a
            scnMat.writesToDepthBuffer = false
        } else if alphaMode == "MASK" {
            scnMat.transparencyMode = .aOne
        }

        let hex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        let info = ThreeDMaterialInfo(
            id: "\(index)-\(name)",
            name: name,
            baseColorHex: hex,
            metalness: metalness,
            roughness: roughness,
            isDoubleSided: scnMat.isDoubleSided,
            alphaMode: alphaMode,
            textureChannels: channels
        )
        return (scnMat, info)
    }

    // MARK: - Nodes & Meshes

    private static func buildNodeRecursive(
        index: Int,
        doc: GLTFDocument,
        buffers: [Data],
        materials: [SCNMaterial],
        nodeMap: inout [String: SCNNode],
        totalVertices: inout Int,
        totalTriangles: inout Int,
        meshCount: inout Int,
        objectCount: inout Int
    ) -> (scnNode: SCNNode, info: ThreeDNodeInfo) {
        let nodeID = "node_\(index)"
        let scnNode = SCNNode()
        let def = (doc.nodes != nil && index < doc.nodes!.count) ? doc.nodes![index] : nil
        let name = (def?.name?.isEmpty == false) ? def!.name! : "Object_\(index + 1)"
        scnNode.name = nodeID
        objectCount += 1

        if let m = def?.matrix, m.count == 16 {
            scnNode.transform = SCNMatrix4(
                m11: m[0], m12: m[1], m13: m[2], m14: m[3],
                m21: m[4], m22: m[5], m23: m[6], m24: m[7],
                m31: m[8], m32: m[9], m33: m[10], m34: m[11],
                m41: m[12], m42: m[13], m43: m[14], m44: m[15]
            )
        } else {
            if let t = def?.translation, t.count == 3 {
                scnNode.position = SCNVector3(t[0], t[1], t[2])
            }
            if let r = def?.rotation, r.count == 4 {
                scnNode.orientation = SCNQuaternion(r[0], r[1], r[2], r[3])
            }
            if let s = def?.scale, s.count == 3 {
                scnNode.scale = SCNVector3(s[0], s[1], s[2])
            }
        }

        var nodeVerts = 0
        var nodeTris = 0
        var matNames: [String] = []
        var hasMesh = false

        if let mIdx = def?.mesh, let meshes = doc.meshes, mIdx < meshes.count {
            hasMesh = true
            meshCount += 1
            let meshDef = meshes[mIdx]
            for (pIdx, primitive) in meshDef.primitives.enumerated() {
                if let built = buildPrimitiveGeometry(primitive, doc: doc, buffers: buffers, materials: materials) {
                    nodeVerts += built.vertexCount
                    nodeTris += built.triangleCount
                    if let mName = built.materialName, !matNames.contains(mName) {
                        matNames.append(mName)
                    }
                    if meshDef.primitives.count == 1 {
                        scnNode.geometry = built.geometry
                    } else {
                        let sub = SCNNode(geometry: built.geometry)
                        sub.name = "\(nodeID)_prim_\(pIdx)"
                        scnNode.addChildNode(sub)
                    }
                }
            }
        }

        totalVertices += nodeVerts
        totalTriangles += nodeTris
        nodeMap[nodeID] = scnNode

        var childInfos: [ThreeDNodeInfo] = []
        for childIdx in def?.children ?? [] {
            let child = buildNodeRecursive(
                index: childIdx,
                doc: doc,
                buffers: buffers,
                materials: materials,
                nodeMap: &nodeMap,
                totalVertices: &totalVertices,
                totalTriangles: &totalTriangles,
                meshCount: &meshCount,
                objectCount: &objectCount
            )
            scnNode.addChildNode(child.scnNode)
            childInfos.append(child.info)
        }

        let radToDeg: Float = 180.0 / .pi
        let info = ThreeDNodeInfo(
            id: nodeID,
            name: name,
            position: ThreeDVector3(x: scnNode.position.x, y: scnNode.position.y, z: scnNode.position.z),
            eulerAnglesDegrees: ThreeDVector3(
                x: scnNode.eulerAngles.x * radToDeg,
                y: scnNode.eulerAngles.y * radToDeg,
                z: scnNode.eulerAngles.z * radToDeg
            ),
            scale: ThreeDVector3(x: scnNode.scale.x, y: scnNode.scale.y, z: scnNode.scale.z),
            hasMesh: hasMesh,
            vertexCount: nodeVerts,
            triangleCount: nodeTris,
            materialNames: matNames,
            isHidden: scnNode.isHidden,
            children: childInfos
        )
        return (scnNode, info)
    }

    private static func buildPrimitiveGeometry(
        _ primitive: GLTFPrimitive,
        doc: GLTFDocument,
        buffers: [Data],
        materials: [SCNMaterial]
    ) -> (geometry: SCNGeometry, vertexCount: Int, triangleCount: Int, materialName: String?)? {
        guard let posIdx = primitive.attributes["POSITION"],
              let positions = readFloatVectors(accessorIndex: posIdx, components: 3, doc: doc, buffers: buffers),
              !positions.isEmpty else {
            return nil
        }

        let vertexCount = positions.count / 3
        let posData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        var sources: [SCNGeometrySource] = [
            SCNGeometrySource(
                data: posData,
                semantic: .vertex,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 3
            )
        ]

        if let normIdx = primitive.attributes["NORMAL"],
           let normals = readFloatVectors(accessorIndex: normIdx, components: 3, doc: doc, buffers: buffers),
           normals.count == vertexCount * 3 {
            let normData = normals.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: normData,
                semantic: .normal,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 3,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 3
            ))
        }

        if let uvIdx = primitive.attributes["TEXCOORD_0"],
           let uvs = readFloatVectors(accessorIndex: uvIdx, components: 2, doc: doc, buffers: buffers),
           uvs.count == vertexCount * 2 {
            let uvData = uvs.withUnsafeBufferPointer { Data(buffer: $0) }
            sources.append(SCNGeometrySource(
                data: uvData,
                semantic: .texcoord,
                vectorCount: vertexCount,
                usesFloatComponents: true,
                componentsPerVector: 2,
                bytesPerComponent: MemoryLayout<Float>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<Float>.size * 2
            ))
        }

        let primitiveMode = primitive.mode ?? 4 // TRIANGLES
        let scnPrimitiveType: SCNGeometryPrimitiveType
        switch primitiveMode {
        case 0: scnPrimitiveType = .point
        case 1: scnPrimitiveType = .line
        case 5: scnPrimitiveType = .triangleStrip
        default: scnPrimitiveType = .triangles
        }

        let indices: [UInt32]
        if let idxAccessor = primitive.indices,
           let parsedIndices = readIndices(accessorIndex: idxAccessor, doc: doc, buffers: buffers) {
            indices = parsedIndices
        } else {
            indices = (0..<UInt32(vertexCount)).map { $0 }
        }

        let indexData = indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let primitiveCount: Int
        switch scnPrimitiveType {
        case .triangles: primitiveCount = indices.count / 3
        case .triangleStrip: primitiveCount = max(0, indices.count - 2)
        case .line: primitiveCount = indices.count / 2
        default: primitiveCount = indices.count
        }

        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: scnPrimitiveType,
            primitiveCount: primitiveCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: sources, elements: [element])
        var materialName: String?
        if let mIdx = primitive.material, mIdx < materials.count {
            geometry.materials = [materials[mIdx]]
            materialName = materials[mIdx].name
        } else {
            let fallback = SCNMaterial()
            fallback.name = "Default PBR"
            fallback.lightingModel = .physicallyBased
            fallback.diffuse.contents = UIColor(white: 0.78, alpha: 1.0)
            fallback.roughness.contents = NSNumber(value: 0.55)
            geometry.materials = [fallback]
            materialName = fallback.name
        }

        let triangles = (scnPrimitiveType == .triangles || scnPrimitiveType == .triangleStrip) ? primitiveCount : 0
        return (geometry, vertexCount, triangles, materialName)
    }

    private static func readFloatVectors(accessorIndex: Int, components: Int, doc: GLTFDocument, buffers: [Data]) -> [Float]? {
        guard let accessors = doc.accessors, accessorIndex < accessors.count else { return nil }
        let acc = accessors[accessorIndex]
        guard let bvIdx = acc.bufferView, let views = doc.bufferViews, bvIdx < views.count else { return nil }
        let bv = views[bvIdx]
        guard bv.buffer < buffers.count else { return nil }
        let buf = buffers[bv.buffer]

        let baseOffset = (bv.byteOffset ?? 0) + (acc.byteOffset ?? 0)
        let elemSize = components * 4
        let stride = max(elemSize, bv.byteStride ?? elemSize)
        guard acc.componentType == 5126 else { return nil } // FLOAT

        var result = [Float](repeating: 0, count: acc.count * components)
        buf.withUnsafeBytes { raw in
            guard let basePtr = raw.baseAddress else { return }
            for i in 0..<acc.count {
                let off = baseOffset + i * stride
                guard off + elemSize <= buf.count else { break }
                for c in 0..<components {
                    var bits: UInt32 = 0
                    memcpy(&bits, basePtr + off + c * 4, 4)
                    result[i * components + c] = Float(bitPattern: UInt32(littleEndian: bits))
                }
            }
        }
        return result
    }

    private static func readIndices(accessorIndex: Int, doc: GLTFDocument, buffers: [Data]) -> [UInt32]? {
        guard let accessors = doc.accessors, accessorIndex < accessors.count else { return nil }
        let acc = accessors[accessorIndex]
        guard let bvIdx = acc.bufferView, let views = doc.bufferViews, bvIdx < views.count else { return nil }
        let bv = views[bvIdx]
        guard bv.buffer < buffers.count else { return nil }
        let buf = buffers[bv.buffer]

        let baseOffset = (bv.byteOffset ?? 0) + (acc.byteOffset ?? 0)
        var out = [UInt32](repeating: 0, count: acc.count)

        switch acc.componentType {
        case 5121: // UNSIGNED_BYTE
            let stride = max(1, bv.byteStride ?? 1)
            for i in 0..<acc.count {
                let off = baseOffset + i * stride
                guard off < buf.count else { break }
                out[i] = UInt32(buf[off])
            }
        case 5123: // UNSIGNED_SHORT
            let stride = max(2, bv.byteStride ?? 2)
            for i in 0..<acc.count {
                let off = baseOffset + i * stride
                guard off + 2 <= buf.count else { break }
                out[i] = UInt32(buf[off]) | (UInt32(buf[off + 1]) << 8)
            }
        case 5125: // UNSIGNED_INT
            let stride = max(4, bv.byteStride ?? 4)
            for i in 0..<acc.count {
                let off = baseOffset + i * stride
                guard off + 4 <= buf.count else { break }
                out[i] = readUInt32LE(buf, at: off)
            }
        default:
            return nil
        }
        return out
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

// MARK: - glTF 2.0 JSON Codable Schema

private struct GLTFDocument: Decodable {
    let scene: Int?
    let scenes: [GLTFScene]?
    let nodes: [GLTFNode]?
    let meshes: [GLTFMesh]?
    let accessors: [GLTFAccessor]?
    let bufferViews: [GLTFBufferView]?
    let buffers: [GLTFBuffer]?
    let materials: [GLTFMaterial]?
    let textures: [GLTFTexture]?
    let images: [GLTFImage]?
    let animations: [GLTFAnimation]?
}

private struct GLTFScene: Decodable {
    let name: String?
    let nodes: [Int]?
}

private struct GLTFNode: Decodable {
    let name: String?
    let mesh: Int?
    let children: [Int]?
    let matrix: [Float]?
    let translation: [Float]?
    let rotation: [Float]?
    let scale: [Float]?
}

private struct GLTFMesh: Decodable {
    let name: String?
    let primitives: [GLTFPrimitive]
}

private struct GLTFPrimitive: Decodable {
    let attributes: [String: Int]
    let indices: Int?
    let material: Int?
    let mode: Int?
}

private struct GLTFAccessor: Decodable {
    let bufferView: Int?
    let byteOffset: Int?
    let componentType: Int
    let count: Int
    let type: String
}

private struct GLTFBufferView: Decodable {
    let buffer: Int
    let byteOffset: Int?
    let byteLength: Int
    let byteStride: Int?
}

private struct GLTFBuffer: Decodable {
    let uri: String?
    let byteLength: Int
}

private struct GLTFTextureInfoRef: Decodable {
    let index: Int
}

private struct GLTFPBRMetallicRoughness: Decodable {
    let baseColorFactor: [Float]?
    let baseColorTexture: GLTFTextureInfoRef?
    let metallicFactor: Float?
    let roughnessFactor: Float?
    let metallicRoughnessTexture: GLTFTextureInfoRef?
}

private struct GLTFMaterial: Decodable {
    let name: String?
    let pbrMetallicRoughness: GLTFPBRMetallicRoughness?
    let normalTexture: GLTFTextureInfoRef?
    let emissiveTexture: GLTFTextureInfoRef?
    let emissiveFactor: [Float]?
    let alphaMode: String?
    let doubleSided: Bool?
}

private struct GLTFTexture: Decodable {
    let name: String?
    let source: Int?
}

private struct GLTFImage: Decodable {
    let name: String?
    let uri: String?
    let bufferView: Int?
    let mimeType: String?
}

private struct GLTFAnimation: Decodable {
    let name: String?
}
