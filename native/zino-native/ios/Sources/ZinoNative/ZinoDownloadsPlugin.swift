import Foundation
import Capacitor

/// Model download manager: pause/resume (URLSession resume data), storage checks and SHA-256
/// verification. Downloaded files are treated as untrusted data: they are only ever opened by
/// the inference runtimes, never executed.
@objc(ZinoDownloadsPlugin)
public class ZinoDownloadsPlugin: CAPPlugin, CAPBridgedPlugin, URLSessionDownloadDelegate {
    public let identifier = "ZinoDownloadsPlugin"
    public let jsName = "ZinoDownloads"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "start", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pause", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancel", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "active", returnType: CAPPluginReturnPromise)
    ]

    private struct Job {
        let id: String
        let dest: String
        let expectedSha256: String?
        let expectedSize: Int64?
        var task: URLSessionDownloadTask?
        var lastBytes: Int64 = 0
        var lastTime = Date()
        var lastEmit = Date.distantPast
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 24
        cfg.waitsForConnectivity = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: delegateQueue)
    }()
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.name = "com.zinoagent.downloads"; return q
    }()
    private var jobs: [String: Job] = [:]           // accessed on delegateQueue only
    private var taskToJob: [Int: String] = [:]

    private static var resumeDir: URL {
        let u = ZinoPaths.root.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static func resumeURL(_ id: String) -> URL { resumeDir.appendingPathComponent("\(id).resume") }

    private static func validId(_ id: String) -> Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
    }

    /// Start a new download, or resume one when resume data exists for `id`.
    @objc func start(_ call: CAPPluginCall) {
        guard let id = call.getString("id"), Self.validId(id) else { call.reject("Invalid id", "INVALID_ARGUMENT"); return }
        guard let urlString = call.getString("url"), let url = URL(string: urlString), url.scheme == "https" else {
            call.reject("Only https downloads are allowed.", "INVALID_ARGUMENT"); return
        }
        guard let dest = call.getString("dest") else { call.reject("dest is required", "INVALID_ARGUMENT"); return }
        let expectedSize = call.getDouble("expectedSize").map { Int64($0) }
        let sha = call.getString("sha256")?.lowercased()
        let headers = call.getObject("headers") ?? [:]
        // Optional Keychain account (e.g. a Hugging Face token for gated repos): injected natively.
        let authSecret = call.getString("authAccount").flatMap { ZinoKeychain.get(account: $0) }
        delegateQueue.addOperation {
            do {
                let destURL = try ZinoPaths.resolve(dest)
                if FileManager.default.fileExists(atPath: destURL.path) {
                    throw ZinoError("FILE_EXISTS", "A file already exists at the destination.")
                }
                if let expectedSize {
                    let free = ZinoPaths.availableCapacity()
                    // Keep 1 GB headroom so the OS and the app stay healthy.
                    if free >= 0 && expectedSize + 1_000_000_000 > free {
                        throw ZinoError("INSUFFICIENT_STORAGE",
                                        "This download needs \(ByteCountFormatter.string(fromByteCount: expectedSize, countStyle: .file)) plus 1 GB headroom, but only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) is free.")
                    }
                }
                if self.jobs[id]?.task != nil { throw ZinoError("ALREADY_RUNNING", "This download is already running.") }
                let task: URLSessionDownloadTask
                let resumeFile = Self.resumeURL(id)
                if let data = try? Data(contentsOf: resumeFile) {
                    task = self.session.downloadTask(withResumeData: data)
                    try? FileManager.default.removeItem(at: resumeFile)
                } else {
                    var req = URLRequest(url: url)
                    for (k, v) in headers { if let s = v as? String { req.setValue(s, forHTTPHeaderField: k) } }
                    if let authSecret { req.setValue("Bearer \(authSecret)", forHTTPHeaderField: "Authorization") }
                    task = self.session.downloadTask(with: req)
                }
                var job = Job(id: id, dest: dest, expectedSha256: sha, expectedSize: expectedSize)
                job.task = task
                self.jobs[id] = job
                self.taskToJob[task.taskIdentifier] = id
                task.resume()
                call.resolve(["started": true])
            } catch { call.zinoReject(error) }
        }
    }

    @objc func pause(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else { call.reject("id required", "INVALID_ARGUMENT"); return }
        delegateQueue.addOperation {
            guard let task = self.jobs[id]?.task else { call.resolve(["paused": false]); return }
            self.jobs[id]?.task = nil
            task.cancel(byProducingResumeData: { data in
                if let data { try? data.write(to: Self.resumeURL(id)) }
                call.resolve(["paused": true, "resumable": data != nil])
            })
        }
    }

    @objc func cancel(_ call: CAPPluginCall) {
        guard let id = call.getString("id") else { call.reject("id required", "INVALID_ARGUMENT"); return }
        delegateQueue.addOperation {
            self.jobs[id]?.task?.cancel()
            self.jobs.removeValue(forKey: id)
            try? FileManager.default.removeItem(at: Self.resumeURL(id))
            call.resolve(["cancelled": true])
        }
    }

    @objc func active(_ call: CAPPluginCall) {
        delegateQueue.addOperation {
            let ids = self.jobs.filter { $0.value.task != nil }.map { $0.key }
            let resumable = ((try? FileManager.default.contentsOfDirectory(atPath: Self.resumeDir.path)) ?? [])
                .filter { $0.hasSuffix(".resume") }.map { String($0.dropLast(7)) }
            call.resolve(["running": ids, "resumable": resumable])
        }
    }

    // MARK: - URLSessionDownloadDelegate (delegateQueue)

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = taskToJob[downloadTask.taskIdentifier], var job = jobs[id] else { return }
        let now = Date()
        guard now.timeIntervalSince(job.lastEmit) > 0.5 else { return }
        let dt = now.timeIntervalSince(job.lastTime)
        let speed = dt > 0 ? Double(totalBytesWritten - job.lastBytes) / dt : 0
        job.lastBytes = totalBytesWritten
        job.lastTime = now
        job.lastEmit = now
        jobs[id] = job
        notifyListeners("progress", data: [
            "id": id, "received": totalBytesWritten,
            "total": totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (job.expectedSize ?? -1),
            "bytesPerSecond": speed
        ])
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = taskToJob[downloadTask.taskIdentifier], let job = jobs[id] else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            jobs.removeValue(forKey: id)
            notifyListeners("error", data: ["id": id, "code": status == 401 || status == 403 ? "DOWNLOAD_FORBIDDEN" : "DOWNLOAD_HTTP_ERROR",
                                            "message": "Server responded with HTTP \(status).", "resumable": false])
            return
        }
        // The temp file is deleted when this method returns: move it synchronously.
        let staging = ZinoPaths.tmp.appendingPathComponent("\(id).verify")
        try? FileManager.default.removeItem(at: staging)
        do { try FileManager.default.moveItem(at: location, to: staging) } catch {
            jobs.removeValue(forKey: id)
            notifyListeners("error", data: ["id": id, "code": "WRITE_FAILED", "message": error.localizedDescription, "resumable": false])
            return
        }
        jobs[id]?.task = nil
        notifyListeners("verifying", data: ["id": id])
        DispatchQueue.global(qos: .utility).async {
            do {
                let size = Int64((try? staging.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if let expected = job.expectedSize, expected > 0, size != expected {
                    throw ZinoError("DOWNLOAD_CORRUPT", "Downloaded size \(size) does not match the expected \(expected) bytes.")
                }
                let digest = try ZinoHash.sha256(of: staging)
                if let expected = job.expectedSha256, !expected.isEmpty, expected != digest {
                    throw ZinoError("CHECKSUM_MISMATCH", "SHA-256 verification failed. The file was discarded.")
                }
                let dest = try ZinoPaths.resolve(job.dest)
                try ZinoPaths.ensureParent(dest)
                if FileManager.default.fileExists(atPath: dest.path) { throw ZinoError("FILE_EXISTS", "Destination already exists.") }
                try FileManager.default.moveItem(at: staging, to: dest)
                self.notifyListeners("complete", data: ["id": id, "path": job.dest, "size": size, "sha256": digest,
                                                        "verified": job.expectedSha256 != nil])
            } catch {
                try? FileManager.default.removeItem(at: staging)
                let z = error as? ZinoError
                self.notifyListeners("error", data: ["id": id, "code": z?.code ?? "WRITE_FAILED", "message": error.localizedDescription, "resumable": false])
            }
            self.delegateQueue.addOperation { self.jobs.removeValue(forKey: id) }
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = taskToJob.removeValue(forKey: task.taskIdentifier) else { return }
        guard let error else { return } // success handled in didFinishDownloadingTo
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled && jobs[id]?.task == nil {
            return // paused or cancelled by the user
        }
        var resumable = false
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: Self.resumeURL(id))
            resumable = true
        }
        jobs.removeValue(forKey: id)
        let code = ns.code == NSURLErrorNotConnectedToInternet || ns.code == NSURLErrorNetworkConnectionLost ? "NETWORK_OFFLINE" : "DOWNLOAD_FAILED"
        notifyListeners("error", data: ["id": id, "code": code, "message": error.localizedDescription, "resumable": resumable])
    }
}
