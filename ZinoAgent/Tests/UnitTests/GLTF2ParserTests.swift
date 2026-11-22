import XCTest
@testable import ZinoAgent

final class GLTF2ParserTests: XCTestCase {
    func testParsesValidMinimalGLBPreservingHierarchyAndMaterial() throws {
        let glbData = try buildMinimalTriangleGLB()
        let loaded = try GLTF2Parser.parse(data: glbData, format: .glb, fileName: "unit_triangle.glb")

        XCTAssertEqual(loaded.metadata.format, .glb)
        XCTAssertEqual(loaded.metadata.objectCount, 2, "Expected ParentAssembly + ChildTriangleMesh nodes preserved without flattening.")
        XCTAssertEqual(loaded.metadata.meshCount, 1)
        XCTAssertEqual(loaded.metadata.vertexCount, 3)
        XCTAssertEqual(loaded.metadata.triangleCount, 1)
        XCTAssertEqual(loaded.metadata.materialCount, 1)
        XCTAssertEqual(loaded.metadata.materials.first?.name, "BrushedSteel")
        XCTAssertEqual(loaded.metadata.rootNodes.first?.name, "ParentAssembly")
        XCTAssertEqual(loaded.metadata.rootNodes.first?.children.first?.name, "ChildTriangleMesh")
        XCTAssertEqual(loaded.metadata.dimensions.x, 2.0, accuracy: 0.01)
        XCTAssertEqual(loaded.metadata.dimensions.y, 1.5, accuracy: 0.01)
    }

    func testRejectsCorruptGLBHeader() {
        let invalid = Data("INVALID_GLB_BINARY_DATA_0000".utf8)
        XCTAssertThrowsError(try GLTF2Parser.parse(data: invalid, format: .glb, fileName: "broken.glb"))
    }

    private func buildMinimalTriangleGLB() throws -> Data {
        // 3 vertices (9 floats = 36 bytes) + 3 UInt16 indices (6 bytes, padded to 8 bytes) = 44 bytes BIN.
        let positions: [Float] = [
            0.0, 0.0, 0.0,
            2.0, 0.0, 0.0,
            1.0, 1.5, 0.0
        ]
        let indices: [UInt16] = [0, 1, 2]

        var bin = Data()
        for f in positions {
            var bits = f.bitPattern.littleEndian
            bin.append(Data(bytes: &bits, count: 4))
        }
        for idx in indices {
            var le = idx.littleEndian
            bin.append(Data(bytes: &le, count: 2))
        }
        while bin.count % 4 != 0 { bin.append(0) }

        let jsonObj: [String: Any] = [
            "asset": ["version": "2.0"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [
                ["name": "ParentAssembly", "children": [1]],
                ["name": "ChildTriangleMesh", "mesh": 0, "translation": [0.0, 0.0, 0.0]]
            ],
            "materials": [[
                "name": "BrushedSteel",
                "pbrMetallicRoughness": [
                    "baseColorFactor": [0.75, 0.78, 0.82, 1.0],
                    "metallicFactor": 0.9,
                    "roughnessFactor": 0.25
                ]
            ]],
            "meshes": [[
                "name": "TriangleMesh",
                "primitives": [[
                    "attributes": ["POSITION": 0],
                    "indices": 1,
                    "material": 0
                ]]
            ]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"],
                ["bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"]
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": 36],
                ["buffer": 0, "byteOffset": 36, "byteLength": 6]
            ],
            "buffers": [
                ["byteLength": bin.count]
            ]
        ]

        var jsonData = try JSONSerialization.data(withJSONObject: jsonObj)
        while jsonData.count % 4 != 0 { jsonData.append(0x20) } // space padding per glTF 2.0 spec

        let totalLength = UInt32(12 + 8 + jsonData.count + 8 + bin.count)
        var glb = Data()
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            glb.append(Data(bytes: &le, count: 4))
        }
        appendU32(0x46546C67) // "glTF"
        appendU32(2)          // version 2
        appendU32(totalLength)

        appendU32(UInt32(jsonData.count))
        appendU32(0x4E4F534A) // "JSON"
        glb.append(jsonData)

        appendU32(UInt32(bin.count))
        appendU32(0x004E4942) // "BIN\0"
        glb.append(bin)

        return glb
    }
}
