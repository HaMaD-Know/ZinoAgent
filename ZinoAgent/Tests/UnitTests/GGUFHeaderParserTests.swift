import XCTest
@testable import ZinoAgent

final class GGUFHeaderParserTests: XCTestCase {
    func testParsesValidGGUFv3HeaderAndEvaluatesMemory() throws {
        let data = makeSyntheticGGUF(
            version: 3,
            architecture: "qwen2",
            name: "Qwen2.5-3B-Instruct",
            contextLength: 32768,
            blockCount: 36,
            embeddingLength: 2048,
            headCount: 16,
            headCountKV: 2,
            fileType: 15 // Q4_K_M
        )

        let meta = try GGUFHeaderParser.parse(data: data, totalFileSize: 2_000_000_000, filename: "qwen2.5-3b-q4_k_m.gguf")
        XCTAssertEqual(meta.version, 3)
        XCTAssertEqual(meta.architecture, "qwen2")
        XCTAssertEqual(meta.name, "Qwen2.5-3B-Instruct")
        XCTAssertEqual(meta.quantizationLabel, "Q4_K_M")
        XCTAssertEqual(meta.trainedContextLength, 32768)
        XCTAssertEqual(meta.blockCount, 36)

        let fitReport = GGUFHeaderParser.evaluateCompatibility(
            metadata: meta,
            targetContextLength: 4096,
            availableHeadroomBytes: 5_500_000_000
        )
        XCTAssertEqual(fitReport.status, .compatible)

        let tightReport = GGUFHeaderParser.evaluateCompatibility(
            metadata: meta,
            targetContextLength: 4096,
            availableHeadroomBytes: 1_800_000_000
        )
        XCTAssertEqual(tightReport.status, .warningHighMemory)
    }

    func testRejectsUnsupportedArchitecture() throws {
        let data = makeSyntheticGGUF(
            version: 3,
            architecture: "exotic_unknown_arch_v99",
            name: "MysteryModel",
            contextLength: 4096,
            blockCount: 12,
            embeddingLength: 1024,
            headCount: 8,
            headCountKV: 8,
            fileType: 15
        )
        let meta = try GGUFHeaderParser.parse(data: data, totalFileSize: 500_000_000)
        let report = GGUFHeaderParser.evaluateCompatibility(
            metadata: meta,
            targetContextLength: 4096,
            availableHeadroomBytes: 5_000_000_000
        )
        XCTAssertEqual(report.status, .incompatibleArchitecture)
        XCTAssertFalse(report.status.canAttemptLoad)
    }

    func testRejectsInvalidMagicBytes() {
        let bogus = Data("NOT_A_GGUF_FILE_1234567890".utf8)
        XCTAssertThrowsError(try GGUFHeaderParser.parse(data: bogus))
    }

    // MARK: - Binary GGUF Builder Helper

    private func makeSyntheticGGUF(
        version: UInt32,
        architecture: String,
        name: String,
        contextLength: UInt32,
        blockCount: UInt32,
        embeddingLength: UInt32,
        headCount: UInt32,
        headCountKV: UInt32,
        fileType: UInt32
    ) -> Data {
        var buf = Data()
        func appendU32(_ v: UInt32) {
            var le = v.littleEndian
            buf.append(Data(bytes: &le, count: 4))
        }
        func appendU64(_ v: UInt64) {
            var le = v.littleEndian
            buf.append(Data(bytes: &le, count: 8))
        }
        func appendStr(_ s: String) {
            let utf8 = Data(s.utf8)
            appendU64(UInt64(utf8.count))
            buf.append(utf8)
        }
        func appendKVString(_ key: String, _ value: String) {
            appendStr(key)
            appendU32(8) // GGUF_TYPE_STRING
            appendStr(value)
        }
        func appendKVUInt32(_ key: String, _ value: UInt32) {
            appendStr(key)
            appendU32(4) // GGUF_TYPE_UINT32
            appendU32(value)
        }

        appendU32(0x46554747) // "GGUF"
        appendU32(version)
        appendU64(10) // tensor count
        appendU64(8)  // kv count

        appendKVString("general.architecture", architecture)
        appendKVString("general.name", name)
        appendKVUInt32("general.file_type", fileType)
        appendKVUInt32("\(architecture).context_length", contextLength)
        appendKVUInt32("\(architecture).block_count", blockCount)
        appendKVUInt32("\(architecture).embedding_length", embeddingLength)
        appendKVUInt32("\(architecture).attention.head_count", headCount)
        appendKVUInt32("\(architecture).attention.head_count_kv", headCountKV)
        return buf
    }
}
