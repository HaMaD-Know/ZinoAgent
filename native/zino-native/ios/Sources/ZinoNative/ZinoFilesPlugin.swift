import Foundation
import Capacitor
import UIKit
import UniformTypeIdentifiers
import PDFKit

/// Access to folders the user explicitly authorises with the iOS Files picker.
///
/// Every operation is validated natively, regardless of what the AI or the JS layer asked for:
///  * the folder must have been authorised (security-scoped bookmark),
///  * the target must resolve inside that folder (no "..", absolute paths or symlink escape),
///  * names are validated, and nothing is ever overwritten on a naming collision,
///  * "delete" moves items into a `.ZinoAgent Trash` folder inside the root so it can be undone.
@objc(ZinoFilesPlugin)
public class ZinoFilesPlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate {
    public let identifier = "ZinoFilesPlugin"
    public let jsName = "ZinoFiles"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "pickFolder", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "listRoots", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "removeRoot", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "list", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stat", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readText", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hash", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "mkdir", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "rename", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "move", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "copy", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "trash", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "restore", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "importToApp", returnType: CAPPluginReturnPromise)
    ]

    static let trashFolderName = ".ZinoAgent Trash"
    private let defaultsKey = "zino.authorizedRoots"
    private let queue = DispatchQueue(label: "com.zinoagent.files", qos: .userInitiated)
    private var pendingPick: CAPPluginCall?

    // MARK: - Root (bookmark) management

    private struct RootRecord: Codable { let id: String; let name: String; var bookmark: Data }

    private func loadRoots() -> [RootRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let roots = try? JSONDecoder().decode([RootRecord].self, from: data) else { return [] }
        return roots
    }

    private func saveRoots(_ roots: [RootRecord]) {
        if let data = try? JSONEncoder().encode(roots) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    /// Resolve a root's bookmark, refreshing it if stale. Caller must stop accessing.
    private func openRoot(_ id: String) throws -> URL {
        var roots = loadRoots()
        guard let idx = roots.firstIndex(where: { $0.id == id }) else {
            throw ZinoError("FOLDER_NOT_AUTHORIZED", "This folder is not authorised. Choose it again in the file manager.")
        }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: roots[idx].bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw ZinoError("FOLDER_ACCESS_LOST", "Access to this folder was lost. Choose it again.")
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw ZinoError("PERMISSION_DENIED", "iPadOS denied access to this folder. Choose it again.")
        }
        if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            roots[idx].bookmark = fresh
            saveRoots(roots)
        }
        return url
    }

    private func withRoot<T>(_ call: CAPPluginCall, _ body: (URL) throws -> T) throws -> T {
        guard let id = call.getString("rootId") else { throw ZinoError("INVALID_ARGUMENT", "rootId is required") }
        let root = try openRoot(id)
        defer { root.stopAccessingSecurityScopedResource() }
        return try body(root)
    }

    @objc func pickFolder(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            guard let vc = self.bridge?.viewController else { call.reject("No view controller", "NATIVE_ERROR"); return }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
            picker.allowsMultipleSelection = false
            picker.delegate = self
            self.pendingPick = call
            vc.present(picker, animated: true)
        }
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let call = pendingPick else { return }
        pendingPick = nil
        guard let url = urls.first else { call.reject("No folder selected", "CANCELLED"); return }
        guard url.startAccessingSecurityScopedResource() else {
            call.reject("iPadOS denied access to the selected folder.", "PERMISSION_DENIED"); return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            var roots = loadRoots()
            let id = UUID().uuidString
            roots.append(RootRecord(id: id, name: url.lastPathComponent, bookmark: bookmark))
            saveRoots(roots)
            call.resolve(["id": id, "name": url.lastPathComponent])
        } catch {
            call.reject("Could not keep access to the folder: \(error.localizedDescription)", "PERMISSION_DENIED")
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingPick?.reject("Selection cancelled", "CANCELLED")
        pendingPick = nil
    }

    @objc func listRoots(_ call: CAPPluginCall) {
        let roots = loadRoots().map { r -> [String: Any] in
            var accessible = false
            if let url = try? openRoot(r.id) { accessible = true; url.stopAccessingSecurityScopedResource() }
            return ["id": r.id, "name": r.name, "accessible": accessible]
        }
        call.resolve(["roots": roots])
    }

    @objc func removeRoot(_ call: CAPPluginCall) {
        guard let id = call.getString("rootId") else { call.reject("rootId is required", "INVALID_ARGUMENT"); return }
        saveRoots(loadRoots().filter { $0.id != id })
        call.resolve()
    }

    // MARK: - Path validation

    static func validateName(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." || name.count > 255 {
            throw ZinoError("INVALID_NAME", "Invalid file name.")
        }
        if name.contains("/") || name.contains(":") || name.contains("\0") {
            throw ZinoError("INVALID_NAME", "File names cannot contain '/', ':' or control characters.")
        }
    }

    /// Resolve `relative` inside `root`. Rejects anything that escapes the authorised folder.
    static func resolve(_ root: URL, _ relative: String) throws -> URL {
        if relative.contains("\0") { throw ZinoError("INVALID_PATH", "Invalid path.") }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.contains(where: { $0 == ".." || $0 == "." }) {
            throw ZinoError("PATH_OUTSIDE_FOLDER", "Paths may not contain '.' or '..'.")
        }
        var url = root
        for p in parts { url.appendPathComponent(p) }
        let rootResolved = root.resolvingSymlinksInPath().standardizedFileURL.path
        // Resolve the deepest existing ancestor so symlinks cannot point outside the root.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path.count > root.path.count {
            probe.deleteLastPathComponent()
        }
        let probeResolved = probe.resolvingSymlinksInPath().standardizedFileURL.path
        guard probeResolved == rootResolved || probeResolved.hasPrefix(rootResolved + "/") else {
            throw ZinoError("PATH_OUTSIDE_FOLDER", "That path is outside the authorised folder.")
        }
        return url
    }

    static func relativePath(_ root: URL, _ url: URL) -> String {
        let r = root.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : (p == r ? "" : url.lastPathComponent)
    }

    private func entry(_ root: URL, _ url: URL) -> [String: Any] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        let v = try? url.resourceValues(forKeys: keys)
        return [
            "path": Self.relativePath(root, url),
            "name": url.lastPathComponent,
            "isDirectory": v?.isDirectory ?? false,
            "size": v?.fileSize ?? 0,
            "modified": ZinoFS.iso(v?.contentModificationDate),
            "created": ZinoFS.iso(v?.creationDate),
            "ext": url.pathExtension.lowercased()
        ]
    }

    private func coordinatedWrite(_ url: URL, forMoving: Bool = false, _ body: (URL) throws -> Void) throws {
        var coordError: NSError?
        var innerError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: forMoving ? .forMoving : [], error: &coordError) { u in
            do { try body(u) } catch { innerError = error }
        }
        if let coordError { throw coordError }
        if let innerError { throw innerError }
    }

    private func run(_ call: CAPPluginCall, _ body: @escaping () throws -> [String: Any]) {
        queue.async {
            do { call.resolve(try body()) } catch { call.zinoReject(error) }
        }
    }

    // MARK: - Read operations

    @objc func list(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let rel = call.getString("path") ?? ""
                let recursive = call.getBool("recursive") ?? false
                let includeHidden = call.getBool("includeHidden") ?? false
                let limit = call.getInt("limit") ?? 5000
                let dir = try Self.resolve(root, rel)
                var out: [[String: Any]] = []
                var truncated = false
                let opts: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
                if recursive {
                    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: opts) else {
                        throw ZinoError("FILE_NOT_FOUND", "Folder not found.")
                    }
                    for case let u as URL in e {
                        if u.lastPathComponent == Self.trashFolderName { e.skipDescendants(); continue }
                        if out.count >= limit { truncated = true; break }
                        out.append(self.entry(root, u))
                    }
                } else {
                    let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: opts)
                    for u in items where u.lastPathComponent != Self.trashFolderName {
                        if out.count >= limit { truncated = true; break }
                        out.append(self.entry(root, u))
                    }
                }
                return ["entries": out, "truncated": truncated]
            }
        }
    }

    @objc func stat(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let url = try Self.resolve(root, call.getString("path") ?? "")
                guard FileManager.default.fileExists(atPath: url.path) else { return ["exists": false] }
                var e = self.entry(root, url)
                e["exists"] = true
                return e
            }
        }
    }

    @objc func readText(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let url = try Self.resolve(root, call.getString("path") ?? "")
                let maxBytes = call.getInt("maxBytes") ?? 512_000
                guard FileManager.default.fileExists(atPath: url.path) else { throw ZinoError("FILE_NOT_FOUND", "File not found.") }
                var result: [String: Any] = [:]
                var coordError: NSError?
                var inner: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
                    do {
                        if u.pathExtension.lowercased() == "pdf" {
                            guard let doc = PDFDocument(url: u) else { throw ZinoError("UNSUPPORTED_FORMAT", "Could not read PDF.") }
                            let text = doc.string ?? ""
                            result = ["text": String(text.prefix(maxBytes)), "truncated": text.count > maxBytes, "pages": doc.pageCount, "format": "pdf"]
                            return
                        }
                        let h = try FileHandle(forReadingFrom: u)
                        defer { try? h.close() }
                        let data = try h.read(upToCount: maxBytes + 1) ?? Data()
                        let truncated = data.count > maxBytes
                        let slice = data.prefix(maxBytes)
                        if slice.prefix(8000).contains(0) {
                            throw ZinoError("UNSUPPORTED_FORMAT", "This looks like a binary file and cannot be read as text.")
                        }
                        result = ["text": String(decoding: slice, as: UTF8.self), "truncated": truncated, "format": "text"]
                    } catch { inner = error }
                }
                if let coordError { throw coordError }
                if let inner { throw inner }
                return result
            }
        }
    }

    @objc func hash(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let url = try Self.resolve(root, call.getString("path") ?? "")
                return ["sha256": try ZinoHash.sha256(of: url)]
            }
        }
    }

    // MARK: - Write operations (never overwrite)

    @objc func mkdir(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let rel = call.getString("path") ?? ""
                let url = try Self.resolve(root, rel)
                try Self.validateName(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: url.path) {
                    throw ZinoError("FILE_EXISTS", "A file or folder with that name already exists.")
                }
                try self.coordinatedWrite(url) { u in try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true) }
                return ["path": Self.relativePath(root, url)]
            }
        }
    }

    @objc func rename(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let src = try Self.resolve(root, call.getString("path") ?? "")
                guard let newName = call.getString("newName") else { throw ZinoError("INVALID_ARGUMENT", "newName is required") }
                try Self.validateName(newName)
                guard Self.relativePath(root, src) != "" else { throw ZinoError("INVALID_PATH", "Cannot rename the authorised folder itself.") }
                guard FileManager.default.fileExists(atPath: src.path) else { throw ZinoError("FILE_NOT_FOUND", "File not found.") }
                let dst = src.deletingLastPathComponent().appendingPathComponent(newName)
                _ = try Self.resolve(root, Self.relativePath(root, dst))
                if FileManager.default.fileExists(atPath: dst.path) && dst.path.lowercased() != src.path.lowercased() {
                    throw ZinoError("FILE_EXISTS", "'\(newName)' already exists. Nothing was overwritten.")
                }
                try self.coordinatedWrite(src, forMoving: true) { u in try FileManager.default.moveItem(at: u, to: dst) }
                return ["from": Self.relativePath(root, src), "to": Self.relativePath(root, dst)]
            }
        }
    }

    @objc func move(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let src = try Self.resolve(root, call.getString("path") ?? "")
                let dstDir = try Self.resolve(root, call.getString("destinationDir") ?? "")
                guard Self.relativePath(root, src) != "" else { throw ZinoError("INVALID_PATH", "Cannot move the authorised folder itself.") }
                guard FileManager.default.fileExists(atPath: src.path) else { throw ZinoError("FILE_NOT_FOUND", "File not found.") }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: dstDir.path, isDirectory: &isDir), isDir.boolValue else {
                    throw ZinoError("FILE_NOT_FOUND", "Destination folder does not exist.")
                }
                if dstDir.standardizedFileURL.path.hasPrefix(src.standardizedFileURL.path + "/") || dstDir.standardizedFileURL == src.standardizedFileURL {
                    throw ZinoError("INVALID_PATH", "Cannot move a folder into itself.")
                }
                let dst = dstDir.appendingPathComponent(src.lastPathComponent)
                if FileManager.default.fileExists(atPath: dst.path) {
                    throw ZinoError("FILE_EXISTS", "'\(src.lastPathComponent)' already exists in the destination. Nothing was overwritten.")
                }
                try self.coordinatedWrite(src, forMoving: true) { u in try FileManager.default.moveItem(at: u, to: dst) }
                return ["from": Self.relativePath(root, src), "to": Self.relativePath(root, dst)]
            }
        }
    }

    @objc func copy(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let src = try Self.resolve(root, call.getString("path") ?? "")
                let dstDir = try Self.resolve(root, call.getString("destinationDir") ?? "")
                guard FileManager.default.fileExists(atPath: src.path) else { throw ZinoError("FILE_NOT_FOUND", "File not found.") }
                var name = call.getString("newName") ?? src.lastPathComponent
                try Self.validateName(name)
                var dst = dstDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: dst.path) {
                    // Copies get a unique suffix rather than replacing anything.
                    let base = (name as NSString).deletingPathExtension
                    let ext = (name as NSString).pathExtension
                    var n = 2
                    repeat {
                        name = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                        dst = dstDir.appendingPathComponent(name)
                        n += 1
                    } while FileManager.default.fileExists(atPath: dst.path) && n < 1000
                }
                try self.coordinatedWrite(dst) { u in try FileManager.default.copyItem(at: src, to: u) }
                return ["from": Self.relativePath(root, src), "to": Self.relativePath(root, dst)]
            }
        }
    }

    /// Reversible delete: moves the item into `.ZinoAgent Trash/<timestamp>/` inside the root.
    @objc func trash(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let src = try Self.resolve(root, call.getString("path") ?? "")
                guard Self.relativePath(root, src) != "" else { throw ZinoError("INVALID_PATH", "Cannot delete the authorised folder itself.") }
                guard FileManager.default.fileExists(atPath: src.path) else { throw ZinoError("FILE_NOT_FOUND", "File not found.") }
                let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
                let bucket = root.appendingPathComponent(Self.trashFolderName).appendingPathComponent(stamp)
                try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
                let dst = bucket.appendingPathComponent(src.lastPathComponent)
                try self.coordinatedWrite(src, forMoving: true) { u in try FileManager.default.moveItem(at: u, to: dst) }
                return ["from": Self.relativePath(root, src), "to": Self.relativePath(root, dst)]
            }
        }
    }

    /// Move an item back (used by undo). Fails rather than overwrite if the original path is taken.
    @objc func restore(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let src = try Self.resolve(root, call.getString("path") ?? "")
                let dst = try Self.resolve(root, call.getString("to") ?? "")
                guard FileManager.default.fileExists(atPath: src.path) else {
                    throw ZinoError("FILE_NOT_FOUND", "The item is no longer where ZinoAgent put it, so it cannot be restored automatically.")
                }
                if FileManager.default.fileExists(atPath: dst.path) {
                    throw ZinoError("FILE_EXISTS", "Something already exists at the original location. Nothing was overwritten.")
                }
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try self.coordinatedWrite(src, forMoving: true) { u in try FileManager.default.moveItem(at: u, to: dst) }
                return ["from": Self.relativePath(root, src), "to": Self.relativePath(root, dst)]
            }
        }
    }

    /// Copy a file from an authorised folder into app storage (e.g. a reference image).
    @objc func importToApp(_ call: CAPPluginCall) {
        run(call) {
            try self.withRoot(call) { root in
                let src = try Self.resolve(root, call.getString("path") ?? "")
                guard let destRel = call.getString("dest") else { throw ZinoError("INVALID_ARGUMENT", "dest is required") }
                let dst = try ZinoPaths.resolve(destRel)
                if FileManager.default.fileExists(atPath: dst.path) { throw ZinoError("FILE_EXISTS", "Destination exists.") }
                try ZinoPaths.ensureParent(dst)
                try FileManager.default.copyItem(at: src, to: dst)
                return ["path": destRel]
            }
        }
    }
}
