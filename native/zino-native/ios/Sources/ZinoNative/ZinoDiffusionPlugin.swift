import Foundation
import Capacitor
import CoreML
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import StableDiffusion

/// Offline text-to-image and image-to-image with Apple's Core ML Stable Diffusion.
/// Models must be *compiled* Core ML resources (TextEncoder.mlmodelc, Unet*.mlmodelc,
/// VAEDecoder.mlmodelc, vocab.json, merges.txt; VAEEncoder.mlmodelc for image-to-image).
@objc(ZinoDiffusionPlugin)
public class ZinoDiffusionPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ZinoDiffusionPlugin"
    public let jsName = "ZinoDiffusion"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "validate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "load", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "unload", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "status", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "generate", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise)
    ]

    private let queue = DispatchQueue(label: "com.zinoagent.diffusion", qos: .userInitiated)
    private var pipeline: StableDiffusionPipelineProtocol?
    private var loadedPath: String?
    private var isXL = false
    private var nativeSize: Int?
    private var cancelled: Set<String> = []
    private let lock = NSLock()

    /// Locate the resource directory: the given folder or a single nested folder containing the files.
    private func resourceDir(_ url: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appendingPathComponent("vocab.json").path) { return url }
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.lastPathComponent == "vocab.json" {
                return u.deletingLastPathComponent()
            }
        }
        return url
    }

    private func describe(_ dir: URL) -> [String: Any] {
        let fm = FileManager.default
        func has(_ n: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(n).path) }
        let hasUnet = has("Unet.mlmodelc") || (has("UnetChunk1.mlmodelc") && has("UnetChunk2.mlmodelc"))
        var missing: [String] = []
        if !has("TextEncoder.mlmodelc") { missing.append("TextEncoder.mlmodelc") }
        if !hasUnet { missing.append("Unet.mlmodelc (or UnetChunk1/2)") }
        if !has("VAEDecoder.mlmodelc") { missing.append("VAEDecoder.mlmodelc") }
        if !has("vocab.json") { missing.append("vocab.json") }
        if !has("merges.txt") { missing.append("merges.txt") }
        let uncompiled = (try? fm.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasSuffix(".mlpackage") } ?? false
        return [
            "valid": missing.isEmpty,
            "missing": missing,
            "isXL": has("TextEncoder2.mlmodelc"),
            "supportsImageToImage": has("VAEEncoder.mlmodelc"),
            "chunkedUnet": has("UnetChunk1.mlmodelc"),
            "hasSafetyChecker": has("SafetyChecker.mlmodelc"),
            "hasUncompiledPackages": uncompiled,
            "nativeSize": Self.latentSize(dir).map { $0 * 8 } ?? NSNull(),
            "resourcePath": ZinoPaths.relative(dir)
        ]
    }

    /// Best-effort read of the decoder's latent input shape from compiled model metadata.
    static func latentSize(_ dir: URL) -> Int? {
        let meta = dir.appendingPathComponent("VAEDecoder.mlmodelc/metadata.json")
        guard let data = try? Data(contentsOf: meta),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let inputs = json.first?["inputSchema"] as? [[String: Any]],
              let shape = inputs.first?["shape"] as? String else { return nil }
        let nums = shape.components(separatedBy: CharacterSet(charactersIn: "[], ")).compactMap { Int($0) }
        return nums.count >= 4 ? nums[nums.count - 1] : nil
    }

    @objc func validate(_ call: CAPPluginCall) {
        guard let rel = call.getString("path") else { call.reject("path is required", "INVALID_ARGUMENT"); return }
        queue.async {
            do {
                let dir = self.resourceDir(try ZinoPaths.resolve(rel))
                call.resolve(self.describe(dir))
            } catch { call.zinoReject(error) }
        }
    }

    @objc func load(_ call: CAPPluginCall) {
        guard let rel = call.getString("path") else { call.reject("path is required", "INVALID_ARGUMENT"); return }
        let units = call.getString("computeUnits") ?? "cpuAndNeuralEngine"
        let reduceMemory = call.getBool("reduceMemory") ?? true
        queue.async {
            do {
                let dir = self.resourceDir(try ZinoPaths.resolve(rel))
                let d = self.describe(dir)
                guard d["valid"] as? Bool == true else {
                    throw ZinoError("UNSUPPORTED_MODEL", "Not a compiled Core ML Stable Diffusion model. Missing: \((d["missing"] as? [String] ?? []).joined(separator: ", ")).")
                }
                self.pipeline?.unloadResources()
                self.pipeline = nil
                let config = MLModelConfiguration()
                switch units {
                case "cpuAndGPU": config.computeUnits = .cpuAndGPU
                case "all": config.computeUnits = .all
                case "cpuOnly": config.computeUnits = .cpuOnly
                default: config.computeUnits = .cpuAndNeuralEngine
                }
                let started = Date()
                let xl = d["isXL"] as? Bool == true
                let p: StableDiffusionPipelineProtocol
                if xl {
                    p = try StableDiffusionXLPipeline(resourcesAt: dir, configuration: config, reduceMemory: reduceMemory)
                } else {
                    p = try StableDiffusionPipeline(resourcesAt: dir, controlNet: [], configuration: config,
                                                    disableSafety: false, reduceMemory: reduceMemory)
                }
                try p.loadResources()
                self.pipeline = p
                self.loadedPath = rel
                self.isXL = xl
                self.nativeSize = (d["nativeSize"] as? Int) ?? (xl ? 1024 : nil)
                call.resolve([
                    "loaded": true, "isXL": xl, "loadMs": Int(Date().timeIntervalSince(started) * 1000),
                    "nativeSize": self.nativeSize ?? NSNull(),
                    "supportsImageToImage": d["supportsImageToImage"] ?? false
                ])
            } catch let e as ZinoError {
                call.zinoReject(e)
            } catch {
                call.reject("Core ML could not load this model: \(error.localizedDescription)", "MODEL_LOAD_FAILED", error)
            }
        }
    }

    @objc func unload(_ call: CAPPluginCall) {
        queue.async {
            self.pipeline?.unloadResources()
            self.pipeline = nil
            self.loadedPath = nil
            call.resolve(["unloaded": true])
        }
    }

    @objc func status(_ call: CAPPluginCall) {
        queue.async {
            call.resolve(["loaded": self.pipeline != nil, "path": self.loadedPath ?? NSNull(), "isXL": self.isXL,
                          "nativeSize": self.nativeSize ?? NSNull()])
        }
    }

    @objc func cancel(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else { call.reject("id required", "INVALID_ARGUMENT"); return }
        lock.lock(); cancelled.insert(id); lock.unlock()
        call.resolve()
    }

    private func isCancelled(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled.contains(id) }

    @objc func generate(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), let prompt = call.getString("prompt") else {
            call.reject("id and prompt are required", "INVALID_ARGUMENT"); return
        }
        guard let outDir = call.getString("outputDir") else { call.reject("outputDir is required", "INVALID_ARGUMENT"); return }
        queue.async {
            defer { self.lock.lock(); self.cancelled.remove(id); self.lock.unlock() }
            guard let pipeline = self.pipeline else { call.reject("No image model loaded", "MODEL_NOT_LOADED"); return }
            do {
                var cfg = PipelineConfiguration(prompt: prompt)
                cfg.negativePrompt = call.getString("negativePrompt") ?? ""
                cfg.stepCount = max(1, min(100, call.getInt("steps") ?? 25))
                cfg.guidanceScale = Float(call.getDouble("guidanceScale") ?? 7.5)
                cfg.imageCount = max(1, min(4, call.getInt("imageCount") ?? 1))
                let seed = UInt32(truncatingIfNeeded: call.getInt("seed") ?? Int.random(in: 0..<Int(UInt32.max)))
                cfg.seed = seed
                cfg.schedulerType = (call.getString("scheduler") == "pndm") ? .pndmScheduler : .dpmSolverMultistepScheduler
                cfg.disableSafety = false
                if self.isXL {
                    cfg.encoderScaleFactor = 0.13025
                    cfg.decoderScaleFactor = 0.13025
                }
                if let startRel = call.getString("startingImage") {
                    let size = self.nativeSize ?? (self.isXL ? 1024 : 512)
                    guard let img = Self.loadImage(try ZinoPaths.resolve(startRel), size: size) else {
                        throw ZinoError("UNSUPPORTED_FORMAT", "Could not read the reference image.")
                    }
                    cfg.startingImage = img
                    cfg.strength = Float(max(0.05, min(0.95, call.getDouble("strength") ?? 0.6)))
                }
                let started = Date()
                let images = try pipeline.generateImages(configuration: cfg) { progress in
                    self.notifyListeners("progress", data: ["id": id, "step": progress.step, "stepCount": progress.stepCount])
                    return !self.isCancelled(id)
                }
                if self.isCancelled(id) { throw ZinoError("CANCELLED", "Generation cancelled.") }
                var results: [[String: Any]] = []
                var filtered = 0
                for (i, image) in images.enumerated() {
                    guard let image else { filtered += 1; continue } // nil = blocked by the model's safety checker
                    let rel = "\(outDir)/\(id)-\(i).png"
                    let url = try ZinoPaths.resolve(rel)
                    try ZinoPaths.ensureParent(url)
                    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                        throw ZinoError("WRITE_FAILED", "Could not create PNG.")
                    }
                    CGImageDestinationAddImage(dest, image, nil)
                    guard CGImageDestinationFinalize(dest) else { throw ZinoError("WRITE_FAILED", "Could not write PNG.") }
                    results.append(["path": rel, "width": image.width, "height": image.height])
                }
                call.resolve([
                    "images": results, "seed": Int(seed), "filteredBySafetyChecker": filtered,
                    "durationMs": Int(Date().timeIntervalSince(started) * 1000)
                ])
            } catch let e as ZinoError {
                call.zinoReject(e)
            } catch {
                call.reject("Image generation failed: \(error.localizedDescription)", "GENERATION_FAILED", error)
            }
        }
    }

    /// Load an image and scale/crop it to the square size the model was compiled for.
    static func loadImage(_ url: URL, size: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let w = CGFloat(img.width), h = CGFloat(img.height)
        let scale = CGFloat(size) / min(w, h)
        let dw = w * scale, dh = h * scale
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: (CGFloat(size) - dw) / 2, y: (CGFloat(size) - dh) / 2, width: dw, height: dh))
        return ctx.makeImage()
    }
}
