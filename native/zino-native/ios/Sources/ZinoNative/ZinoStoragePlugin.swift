import Foundation
import Capacitor
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

/// App-private storage: generated assets, imported/downloaded models, temporary files.
/// Paths exchanged with JS are always relative to Application Support/ZinoAgent.
@objc(ZinoStoragePlugin)
public class ZinoStoragePlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate {
    public let identifier = "ZinoStoragePlugin"
    public let jsName = "ZinoStorage"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "info", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "writeBase64", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readBase64", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "writeText", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readText", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stat", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "list", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "remove", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "copy", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "move", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "fileUrl", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "hash", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unzip", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "directorySize", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearTemp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pickAndImport", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "share", returnType: CAPPluginReturnPromise)
    ]

    private let queue = DispatchQueue(label: "com.zinoagent.storage", qos: .userInitiated)
    private var pendingImport: (call: CAPPluginCall, destDir: String, folder: Bool)?

    private func run(_ call: CAPPluginCall, _ body: @escaping () throws -> [String: Any]) {
        queue.async { do { call.resolve(try body()) } catch { call.zinoReject(error) } }
    }

    private func path(_ call: CAPPluginCall, _ key: String = "path") throws -> URL {
        guard let rel = call.getString(key) else { throw ZinoError("INVALID_ARGUMENT", "\(key) is required") }
        return try ZinoPaths.resolve(rel)
    }

    @objc func info(_ call: CAPPluginCall) {
        run(call) {
            let values = try? ZinoPaths.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            return [
                "root": ZinoPaths.root.path,
                "available": values?.volumeAvailableCapacityForImportantUsage ?? -1,
                "total": values?.volumeTotalCapacity ?? -1
            ]
        }
    }

    @objc func writeBase64(_ call: CAPPluginCall) {
        run(call) {
            let url = try self.path(call)
            guard let b64 = call.getString("data"), let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
                throw ZinoError("INVALID_ARGUMENT", "data must be base64")
            }
            if FileManager.default.fileExists(atPath: url.path) && !(call.getBool("overwrite") ?? false) {
                throw ZinoError("FILE_EXISTS", "File already exists.")
            }
            try ZinoPaths.ensureParent(url)
            try data.write(to: url, options: .atomic)
            return ["path": ZinoPaths.relative(url), "size": data.count]
        }
    }

    @objc func readBase64(_ call: CAPPluginCall) {
        run(call) {
            let url = try self.path(call)
            let data = try Data(contentsOf: url)
            return ["data": data.base64EncodedString()]
        }
    }

    @objc func writeText(_ call: CAPPluginCall) {
        run(call) {
            let url = try self.path(call)
            let text = call.getString("text") ?? ""
            try ZinoPaths.ensureParent(url)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return ["path": ZinoPaths.relative(url)]
        }
    }

    @objc func readText(_ call: CAPPluginCall) {
        run(call) {
            let url = try self.path(call)
            return ["text": try String(contentsOf: url, encoding: .utf8)]
        }
    }

    @objc func stat(_ call: CAPPluginCall) {
        run(call) {
            let url = try self.path(call)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return ["exists": false] }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return [
                "exists": true,
                "isDirectory": isDir.boolValue,
                "size": isDir.boolValue ? ZinoFS.directorySize(url) : Int64(v?.fileSize ?? 0),
                "modified": ZinoFS.iso(v?.contentModificationDate)
            ]
        }
    }

    @objc func list(_ call: CAPPluginCall) {
        run(call) {
            let url = try self.path(call)
            guard FileManager.default.fileExists(atPath: url.path) else { return ["entries": []] }
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])
            let entries: [[String: Any]] = items.map { u in
                let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                return ["path": ZinoPaths.relative(u), "name": u.lastPathComponent, "isDirectory": v?.isDirectory ?? false, "size": v?.fileSize ?? 0]
            }
            return ["entries": entries]
        }
    }

    @objc func remove(_ call: CAPPluginCall) {
        run(call) {
            let url = try self.path(call)
            if url.standardizedFileURL.path == ZinoPaths.root.standardizedFileURL.path {
                throw ZinoError("INVALID_PATH", "Refusing to remove storage root.")
            }
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return ["removed": true]
        }
    }

    @objc func copy(_ call: CAPPluginCall) {
        run(call) {
            let src = try self.path(call, "from")
            let dst = try self.path(call, "to")
            if FileManager.default.fileExists(atPath: dst.path) { throw ZinoError("FILE_EXISTS", "Destination exists.") }
            try ZinoPaths.ensureParent(dst)
            try FileManager.default.copyItem(at: src, to: dst)
            return ["path": ZinoPaths.relative(dst)]
        }
    }

    @objc func move(_ call: CAPPluginCall) {
        run(call) {
            let src = try self.path(call, "from")
            let dst = try self.path(call, "to")
            if FileManager.default.fileExists(atPath: dst.path) { throw ZinoError("FILE_EXISTS", "Destination exists.") }
            try ZinoPaths.ensureParent(dst)
            try FileManager.default.moveItem(at: src, to: dst)
            return ["path": ZinoPaths.relative(dst)]
        }
    }

    /// Absolute file:// URL; the JS layer converts it with Capacitor.convertFileSrc for <img>/<video>.
    @objc func fileUrl(_ call: CAPPluginCall) {
        run(call) { ["url": try self.path(call).absoluteString] }
    }

    @objc func hash(_ call: CAPPluginCall) {
        run(call) { ["sha256": try ZinoHash.sha256(of: try self.path(call))] }
    }

    @objc func unzip(_ call: CAPPluginCall) {
        run(call) {
            let src = try self.path(call)
            let dst = try self.path(call, "destination")
            if FileManager.default.fileExists(atPath: dst.path) { throw ZinoError("FILE_EXISTS", "Destination exists.") }
            if let size = try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                // Unzipped Core ML packages are roughly the size of the archive (they are already compressed weights).
                let free = ZinoPaths.availableCapacity()
                if free >= 0 && Int64(size) > free {
                    throw ZinoError("INSUFFICIENT_STORAGE", "Not enough free storage to extract this archive.")
                }
            }
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
            do {
                try FileManager.default.unzipItem(at: src, to: dst)
            } catch {
                try? FileManager.default.removeItem(at: dst)
                throw ZinoError("UNZIP_FAILED", "Could not extract archive: \(error.localizedDescription)")
            }
            return ["path": ZinoPaths.relative(dst)]
        }
    }

    @objc func directorySize(_ call: CAPPluginCall) {
        run(call) { ["size": ZinoFS.directorySize(try self.path(call))] }
    }

    /// Clears temporary/cache data only. Models, assets and the database are never touched.
    @objc func clearTemp(_ call: CAPPluginCall) {
        run(call) {
            var freed: Int64 = 0
            for dir in [ZinoPaths.tmp, FileManager.default.temporaryDirectory] {
                let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                for item in items {
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir)
                    freed += isDir.boolValue ? ZinoFS.directorySize(item) : Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    try? FileManager.default.removeItem(at: item)
                }
            }
            URLCache.shared.removeAllCachedResponses()
            return ["freed": freed]
        }
    }

    // MARK: - Import via Files picker

    /// kinds: gguf | image | model3d | video | coreml | zip | folder | any
    @objc func pickAndImport(_ call: CAPPluginCall) {
        let kind = call.getString("kind") ?? "any"
        guard let destDir = call.getString("destDir") else { call.reject("destDir is required", "INVALID_ARGUMENT"); return }
        let multiple = call.getBool("multiple") ?? false
        var types: [UTType]
        switch kind {
        case "gguf": types = [UTType(filenameExtension: "gguf") ?? .data, .data]
        case "image": types = [.image]
        case "model3d": types = ["glb", "gltf", "obj", "usdz", "fbx", "ply", "stl"].compactMap { UTType(filenameExtension: $0) } + [.data]
        case "video": types = [.movie, .video, .mpeg4Movie]
        case "coreml": types = [.folder, .zip] + ["mlpackage", "mlmodel", "mlmodelc"].compactMap { UTType(filenameExtension: $0) }
        case "zip": types = [.zip]
        case "folder": types = [.folder]
        default: types = [.item]
        }
        DispatchQueue.main.async {
            guard let vc = self.bridge?.viewController else { call.reject("No view controller", "NATIVE_ERROR"); return }
            // Folders cannot be opened "as copy", so they are copied after security-scoped access.
            let openFolders = kind == "folder" || kind == "coreml"
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: !openFolders)
            picker.allowsMultipleSelection = multiple
            picker.delegate = self
            self.pendingImport = (call, destDir, openFolders)
            vc.present(picker, animated: true)
        }
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        let call = pending.call
        queue.async {
            do {
                let destDir = try ZinoPaths.resolve(pending.destDir)
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                var imported: [[String: Any]] = []
                for src in urls {
                    let scoped = src.startAccessingSecurityScopedResource()
                    defer { if scoped { src.stopAccessingSecurityScopedResource() } }
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: src.path, isDirectory: &isDir)
                    let size = isDir.boolValue ? ZinoFS.directorySize(src) : Int64((try? src.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    let free = ZinoPaths.availableCapacity()
                    if free >= 0 && size > free {
                        throw ZinoError("INSUFFICIENT_STORAGE", "Not enough free storage to import \(src.lastPathComponent).")
                    }
                    var dst = destDir.appendingPathComponent(src.lastPathComponent)
                    var n = 2
                    while FileManager.default.fileExists(atPath: dst.path) {
                        let base = (src.lastPathComponent as NSString).deletingPathExtension
                        let ext = src.pathExtension
                        dst = destDir.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
                        n += 1
                    }
                    var coordError: NSError?
                    var inner: Error?
                    NSFileCoordinator().coordinate(readingItemAt: src, options: [.withoutChanges], error: &coordError) { u in
                        do {
                            if pending.folder {
                                try FileManager.default.copyItem(at: u, to: dst)
                            } else {
                                // asCopy pickers hand us a temporary copy we can move.
                                do { try FileManager.default.moveItem(at: u, to: dst) } catch { try FileManager.default.copyItem(at: u, to: dst) }
                            }
                        } catch { inner = error }
                    }
                    if let coordError { throw coordError }
                    if let inner { throw inner }
                    imported.append([
                        "path": ZinoPaths.relative(dst),
                        "name": dst.lastPathComponent,
                        "originalName": src.lastPathComponent,
                        "size": size,
                        "isDirectory": isDir.boolValue
                    ])
                }
                call.resolve(["files": imported])
            } catch {
                call.zinoReject(error)
            }
        }
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingImport?.call.reject("Import cancelled", "CANCELLED")
        pendingImport = nil
    }

    // MARK: - Export via share sheet (Save to Files, AirDrop, other apps)

    @objc func share(_ call: CAPPluginCall) {
        let url: URL
        do { url = try path(call) } catch { call.zinoReject(error); return }
        guard FileManager.default.fileExists(atPath: url.path) else { call.reject("File not found", "FILE_NOT_FOUND"); return }
        DispatchQueue.main.async {
            guard let vc = self.bridge?.viewController else { call.reject("No view controller", "NATIVE_ERROR"); return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            // iPad requires a popover anchor or UIKit raises an exception.
            if let pop = activity.popoverPresentationController {
                pop.sourceView = vc.view
                pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 1, height: 1)
                pop.permittedArrowDirections = []
            }
            activity.completionWithItemsHandler = { _, completed, _, error in
                if let error { call.reject(error.localizedDescription, "EXPORT_FAILED") } else { call.resolve(["completed": completed]) }
            }
            vc.present(activity, animated: true)
        }
    }
}
