import Foundation
import PDFKit
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

public struct ExtractedDocument: Sendable {
    public let title: String
    public let format: String
    public let text: String
    public let pageCount: Int?
    public let truncated: Bool
    public let characterCount: Int
}

public struct ZipArchiveEntry: Identifiable, Sendable {
    public let id: String
    public let path: String
    public let uncompressedSize: UInt64
    public let isDirectory: Bool
}

/// Extracts readable text from supported documents (PDF, TXT, MD, DOCX, CSV, JSON, XML, source code, ZIP listings).
public enum DocumentTextExtractor {
    public static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "toml",
        "swift", "py", "js", "jsx", "ts", "tsx", "html", "htm", "css", "scss", "lua",
        "c", "h", "cpp", "hpp", "m", "mm", "rs", "go", "java", "kt", "sh", "bash", "zsh",
        "sql", "rb", "php", "plist", "entitlements", "strings", "log", "ini", "env", "gitignore"
    ]

    public static func isTextReadable(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return plainTextExtensions.contains(ext) || ext == "pdf" || ext == "docx" || ext == "zip"
    }

    public static func extract(from url: URL, maxCharacters: Int = 80_000) throws -> ExtractedDocument {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent

        if ext == "pdf" {
            return try extractPDF(from: url, title: name, maxCharacters: maxCharacters)
        } else if ext == "docx" {
            return try extractDOCX(from: url, title: name, maxCharacters: maxCharacters)
        } else if ext == "zip" {
            let entries = try listZipContents(at: url)
            let listing = entries.map { entry in
                let prefix = entry.isDirectory ? "[DIR] " : ""
                let sizeStr = entry.isDirectory ? "" : " (\(Formatters.bytes(Int64(entry.uncompressedSize))))"
                return "\(prefix)\(entry.path)\(sizeStr)"
            }.joined(separator: "\n")
            let clipped = String(listing.prefix(maxCharacters))
            return ExtractedDocument(
                title: name,
                format: "ZIP",
                text: "ZIP Archive (\(entries.count) entries):\n\(clipped)",
                pageCount: nil,
                truncated: listing.count > maxCharacters,
                characterCount: listing.count
            )
        } else if plainTextExtensions.contains(ext) || ext.isEmpty {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .isoLatin1) else {
                throw ZinoError(.unsupportedFormat, "File '\(name)' could not be decoded as text.")
            }
            let truncated = text.count > maxCharacters
            return ExtractedDocument(
                title: name,
                format: ext.isEmpty ? "TEXT" : ext.uppercased(),
                text: truncated ? String(text.prefix(maxCharacters)) : text,
                pageCount: nil,
                truncated: truncated,
                characterCount: text.count
            )
        }

        throw ZinoError(
            .unsupportedFormat,
            "Text extraction is not supported for .\(ext) files. Supported text/document formats: PDF, DOCX, TXT, MD, CSV, JSON, XML, ZIP, and code files."
        )
    }

    private static func extractPDF(from url: URL, title: String, maxCharacters: Int) throws -> ExtractedDocument {
        guard let pdf = PDFDocument(url: url) else {
            throw ZinoError(.unsupportedFormat, "Could not open PDF '\(title)'.")
        }
        var chunks: [String] = []
        var totalChars = 0
        var truncated = false
        for idx in 0..<pdf.pageCount {
            if let page = pdf.page(at: idx), let pageText = page.string {
                let block = "--- Page \(idx + 1) ---\n\(pageText)"
                if totalChars + block.count > maxCharacters {
                    let remaining = max(0, maxCharacters - totalChars)
                    chunks.append(String(block.prefix(remaining)))
                    truncated = true
                    break
                }
                chunks.append(block)
                totalChars += block.count
            }
        }
        let combined = chunks.joined(separator: "\n\n")
        return ExtractedDocument(
            title: title,
            format: "PDF",
            text: combined.isEmpty ? "(PDF contains no extractable text; it may contain scanned images.)" : combined,
            pageCount: pdf.pageCount,
            truncated: truncated,
            characterCount: combined.count
        )
    }

    private static func extractDOCX(from url: URL, title: String, maxCharacters: Int) throws -> ExtractedDocument {
        #if canImport(ZIPFoundation)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ZinoError(.unsupportedFormat, "Could not open DOCX archive '\(title)': \(error.localizedDescription)")
        }
        guard let docEntry = archive["word/document.xml"] else {
            throw ZinoError(.unsupportedFormat, "DOCX '\(title)' does not contain word/document.xml.")
        }
        var xmlData = Data()
        _ = try archive.extract(docEntry) { chunk in
            xmlData.append(chunk)
        }
        let parser = DOCXTextXMLParser()
        let text = parser.parse(data: xmlData)
        let truncated = text.count > maxCharacters
        return ExtractedDocument(
            title: title,
            format: "DOCX",
            text: truncated ? String(text.prefix(maxCharacters)) : text,
            pageCount: nil,
            truncated: truncated,
            characterCount: text.count
        )
        #else
        throw ZinoError(.unsupportedFormat, "ZIPFoundation is unavailable in this build to read DOCX files.")
        #endif
    }

    public static func listZipContents(at url: URL) throws -> [ZipArchiveEntry] {
        #if canImport(ZIPFoundation)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw ZinoError(.unsupportedFormat, "Could not read ZIP archive: \(error.localizedDescription)")
        }
        var entries: [ZipArchiveEntry] = []
        for entry in archive {
            entries.append(ZipArchiveEntry(
                id: entry.path,
                path: entry.path,
                uncompressedSize: entry.uncompressedSize,
                isDirectory: entry.type == .directory
            ))
        }
        return entries.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        #else
        throw ZinoError(.unsupportedFormat, "ZIPFoundation is unavailable in this build.")
        #endif
    }
}

private final class DOCXTextXMLParser: NSObject, XMLParserDelegate {
    private var output = ""
    private var insideTextRun = false

    func parse(data: Data) -> String {
        output = ""
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "w:t" || elementName.hasSuffix(":t") {
            insideTextRun = true
        } else if elementName == "w:tab" || elementName.hasSuffix(":tab") {
            output.append("\t")
        } else if elementName == "w:br" || elementName.hasSuffix(":br") {
            output.append("\n")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideTextRun {
            output.append(string)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" || elementName.hasSuffix(":t") {
            insideTextRun = false
        } else if elementName == "w:p" || elementName.hasSuffix(":p") {
            output.append("\n")
        }
    }
}
