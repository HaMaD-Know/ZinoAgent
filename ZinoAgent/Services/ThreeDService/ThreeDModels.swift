import Foundation
import UIKit
import SceneKit

public enum ThreeDFormat: String, CaseIterable, Codable, Sendable {
    case glb, gltf, usdz, obj, stl

    public static func from(url: URL) -> ThreeDFormat? {
        ThreeDFormat(rawValue: url.pathExtension.lowercased())
    }

    public var displayName: String { rawValue.uppercased() }
}

public enum ThreeDLightingPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case studio
    case daylight
    case dramatic
    case soft

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .studio: return "Studio 3-Point"
        case .daylight: return "Daylight"
        case .dramatic: return "Dramatic Rim"
        case .soft: return "Soft Diffused"
        }
    }
}

public enum ThreeDEnvironmentPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case darkStudio
    case lightStudio
    case neutralSlate
    case pureBlack

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .darkStudio: return "Dark Studio"
        case .lightStudio: return "Light Studio"
        case .neutralSlate: return "Neutral Slate"
        case .pureBlack: return "Pitch Black"
        }
    }

    public var backgroundColor: UIColor {
        switch self {
        case .darkStudio: return UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1.0)
        case .lightStudio: return UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1.0)
        case .neutralSlate: return UIColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1.0)
        case .pureBlack: return UIColor.black
        }
    }
}

public struct ThreeDVector3: Codable, Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float

    public init(x: Float, y: Float, z: Float) {
        self.x = x; self.y = y; self.z = z
    }

    public var formatted: String {
        String(format: "(%.3f, %.3f, %.3f)", x, y, z)
    }
}

public struct ThreeDNodeInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let position: ThreeDVector3
    public let eulerAnglesDegrees: ThreeDVector3
    public let scale: ThreeDVector3
    public let hasMesh: Bool
    public let vertexCount: Int
    public let triangleCount: Int
    public let materialNames: [String]
    public var isHidden: Bool
    public var children: [ThreeDNodeInfo]
}

public struct ThreeDMaterialInfo: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let baseColorHex: String
    public let metalness: Float
    public let roughness: Float
    public let isDoubleSided: Bool
    public let alphaMode: String
    public let textureChannels: [String]
}

public struct ThreeDTextureInfo: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let channel: String
    public let width: Int
    public let height: Int
    public let previewImage: UIImage?
}

public struct ThreeDModelMetadata: Sendable {
    public let format: ThreeDFormat
    public let fileName: String
    public let fileSizeBytes: Int64
    public let dimensions: ThreeDVector3
    public let objectCount: Int
    public let meshCount: Int
    public let materialCount: Int
    public let textureCount: Int
    public let vertexCount: Int
    public let triangleCount: Int
    public let animationNames: [String]
    public let loadDurationMs: Int
    public let rootNodes: [ThreeDNodeInfo]
    public let materials: [ThreeDMaterialInfo]
    public let textures: [ThreeDTextureInfo]

    public func summaryForAI() -> String {
        let anims = animationNames.isEmpty ? "None" : animationNames.joined(separator: ", ")
        let mats = materials.prefix(10).map { "\($0.name) (color \($0.baseColorHex), metalness \(String(format: "%.2f", $0.metalness)), roughness \(String(format: "%.2f", $0.roughness)))" }.joined(separator: "; ")
        let topObjects = rootNodes.prefix(12).map(\.name).joined(separator: ", ")
        return """
        3D Model: \(fileName) (\(format.displayName))
        File Size: \(Formatters.bytes(fileSizeBytes))
        Bounding Dimensions (W×H×D): \(String(format: "%.3f × %.3f × %.3f", dimensions.x, dimensions.y, dimensions.z))
        Objects: \(objectCount) | Meshes: \(meshCount) | Vertices: \(vertexCount) | Triangles: \(triangleCount)
        Materials (\(materialCount)): \(mats.isEmpty ? "Default" : mats)
        Textures: \(textureCount) | Animations: \(anims)
        Top-Level Hierarchy: \(topObjects)
        """
    }
}

public struct LoadedThreeDModel: @unchecked Sendable {
    public let scene: SCNScene
    public let modelRootNode: SCNNode
    public let metadata: ThreeDModelMetadata
    public let nodeMap: [String: SCNNode]
}

public struct ThreeDProjectRecord: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let format: ThreeDFormat
    public let relativeFilePath: String
    public let originalPath: String?
    public let fileSizeBytes: Int64
    public let objectCount: Int
    public let meshCount: Int
    public let materialCount: Int
    public let vertexCount: Int
    public let lastOpenedAt: Date
    public let createdAt: Date
}
