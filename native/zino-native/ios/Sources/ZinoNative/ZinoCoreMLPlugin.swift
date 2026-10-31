import Foundation
import Capacitor
import CoreML

/// Inspects imported Core ML models (.mlpackage / .mlmodel / .mlmodelc): compiles them if
/// needed, loads the description, and reports inputs/outputs/metadata. ZinoAgent uses this to
/// decide whether an imported 3D or video model matches a supported adapter interface instead
/// of pretending that any file can run.
@objc(ZinoCoreMLPlugin)
public class ZinoCoreMLPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ZinoCoreMLPlugin"
    public let jsName = "ZinoCoreML"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "inspect", returnType: CAPPluginReturnPromise)
    ]

    private func describeFeature(_ f: MLFeatureDescription) -> [String: Any] {
        var d: [String: Any] = ["name": f.name, "optional": f.isOptional]
        switch f.type {
        case .multiArray:
            d["type"] = "multiArray"
            if let c = f.multiArrayConstraint { d["shape"] = c.shape.map { $0.intValue } }
        case .image:
            d["type"] = "image"
            if let c = f.imageConstraint { d["width"] = c.pixelsWide; d["height"] = c.pixelsHigh }
        case .string: d["type"] = "string"
        case .int64: d["type"] = "int64"
        case .double: d["type"] = "double"
        case .dictionary: d["type"] = "dictionary"
        case .sequence: d["type"] = "sequence"
        default: d["type"] = "other"
        }
        return d
    }

    @objc func inspect(_ call: CAPPluginCall) {
        guard let rel = call.getString("path") else { call.reject("path is required", "INVALID_ARGUMENT"); return }
        Task.detached(priority: .userInitiated) {
            do {
                var url = try ZinoPaths.resolve(rel)
                let ext = url.pathExtension.lowercased()
                var compiledPath: String?
                if ext == "mlpackage" || ext == "mlmodel" {
                    let compiled = try await MLModel.compileModel(at: url)
                    let dest = url.deletingPathExtension().appendingPathExtension("mlmodelc")
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try FileManager.default.moveItem(at: compiled, to: dest)
                    }
                    url = dest
                    compiledPath = ZinoPaths.relative(dest)
                } else if ext != "mlmodelc" {
                    throw ZinoError("UNSUPPORTED_FORMAT", "Not a Core ML model (.mlpackage, .mlmodel or .mlmodelc).")
                }
                let cfg = MLModelConfiguration()
                cfg.computeUnits = .cpuOnly // inspection only; keeps memory use low
                let model = try await MLModel.load(contentsOf: url, configuration: cfg)
                let desc = model.modelDescription
                let meta = desc.metadata
                call.resolve([
                    "compiledPath": compiledPath ?? rel,
                    "inputs": desc.inputDescriptionsByName.values.map { self.describeFeature($0) },
                    "outputs": desc.outputDescriptionsByName.values.map { self.describeFeature($0) },
                    "author": meta[.author] as? String ?? "",
                    "description": meta[.description] as? String ?? "",
                    "license": meta[.license] as? String ?? "",
                    "version": meta[.versionString] as? String ?? ""
                ])
            } catch let e as ZinoError {
                call.zinoReject(e)
            } catch {
                call.reject("Core ML could not open this model: \(error.localizedDescription)", "UNSUPPORTED_MODEL", error)
            }
        }
    }
}
