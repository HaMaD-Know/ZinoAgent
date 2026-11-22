import Foundation

public enum Formatters {
    public static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, count))
    }

    public static func memory(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb >= 1.0 {
            return String(format: "%.2f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }

    public static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.2fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    public static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    public static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func speed(_ tokensPerSecond: Double) -> String {
        String(format: "%.1f tok/s", tokensPerSecond)
    }
}

/// Incrementally decodes UTF-8 byte streams without corrupting multi-byte emoji or CJK codepoints split across tokens.
public struct UTF8StreamAccumulator: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func append(_ data: Data) -> String {
        buffer.append(contentsOf: data)
        return drainCompleteUTF8()
    }

    public mutating func append(_ bytes: [UInt8]) -> String {
        buffer.append(contentsOf: bytes)
        return drainCompleteUTF8()
    }

    public mutating func flush() -> String {
        guard !buffer.isEmpty else { return "" }
        let result = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return result
    }

    private mutating func drainCompleteUTF8() -> String {
        guard !buffer.isEmpty else { return "" }
        // Find trailing incomplete UTF-8 sequence (at most 3 trailing bytes).
        var validCount = buffer.count
        let checkLimit = min(4, buffer.count)
        for trailing in 1...checkLimit {
            let idx = buffer.count - trailing
            let lead = buffer[idx]
            let expectedLen: Int
            if lead & 0x80 == 0 {
                expectedLen = 1
            } else if lead & 0xE0 == 0xC0 {
                expectedLen = 2
            } else if lead & 0xF0 == 0xE0 {
                expectedLen = 3
            } else if lead & 0xF8 == 0xF0 {
                expectedLen = 4
            } else {
                // Continuation byte; keep scanning backwards for leading byte.
                continue
            }
            if trailing < expectedLen {
                validCount = idx
            }
            break
        }

        guard validCount > 0 else { return "" }
        let slice = Array(buffer.prefix(validCount))
        buffer.removeFirst(validCount)
        return String(decoding: slice, as: UTF8.self)
    }
}
