import Foundation
import Combine
import CryptoKit

public struct ActiveModelDownload: Identifiable, Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case downloading
        case paused
        case verifying
        case completed
        case failed
    }

    public let id: String
    public let name: String
    public let filename: String
    public let sourceURL: URL
    public var state: State
    public var bytesDownloaded: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Double
    public var errorMessage: String?

    public var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(bytesDownloaded) / Double(totalBytes)))
    }
}

/// Manages GGUF model downloads with pause/resume support via URLSession resumeData,
/// progress tracking, and SHA-256 verification.
@MainActor
public final class ModelDownloadManager: NSObject, ObservableObject {
    @Published public private(set) var activeDownloads: [String: ActiveModelDownload] = [:]

    public var onDownloadCompleted: ((URL, String, String, String?) -> Void)?

    private let storagePaths: AppStoragePaths
    private var session: URLSession!
    private var tasksByID: [String: URLSessionDownloadTask] = [:]
    private var idByTaskIdentifier: [Int: String] = [:]
    private var resumeDataByID: [String: Data] = [:]
    private var lastSampleByID: [String: (date: Date, bytes: Int64)] = [:]

    public init(storagePaths: AppStoragePaths) {
        self.storagePaths = storagePaths
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60 * 60 * 4
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func startDownload(id: String = UUID().uuidString, name: String, url: URL, filename: String) throws {
        try HTTPClient.validateURL(url)
        if let existing = activeDownloads[id], existing.state == .downloading {
            return
        }

        let cleanFilename = filename.hasSuffix(".gguf") ? filename : "\(filename).gguf"
        let task = session.downloadTask(with: url)
        tasksByID[id] = task
        idByTaskIdentifier[task.taskIdentifier] = id
        lastSampleByID[id] = (Date(), 0)

        activeDownloads[id] = ActiveModelDownload(
            id: id,
            name: name,
            filename: cleanFilename,
            sourceURL: url,
            state: .downloading,
            bytesDownloaded: 0,
            totalBytes: 0,
            bytesPerSecond: 0,
            errorMessage: nil
        )
        task.resume()
        AppLogger.shared.info("Downloads", "Started model download '\(name)' (\(cleanFilename))")
    }

    public func pauseDownload(id: String) {
        guard let task = tasksByID[id] else { return }
        task.cancel { [weak self] resumeData in
            Task { @MainActor in
                guard let self else { return }
                if let resumeData {
                    self.resumeDataByID[id] = resumeData
                }
                self.tasksByID.removeValue(forKey: id)
                if var dl = self.activeDownloads[id] {
                    dl.state = .paused
                    dl.bytesPerSecond = 0
                    self.activeDownloads[id] = dl
                }
            }
        }
    }

    public func resumeDownload(id: String) {
        guard var dl = activeDownloads[id], dl.state == .paused || dl.state == .failed else { return }
        let task: URLSessionDownloadTask
        if let resumeData = resumeDataByID.removeValue(forKey: id) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: dl.sourceURL)
        }
        tasksByID[id] = task
        idByTaskIdentifier[task.taskIdentifier] = id
        lastSampleByID[id] = (Date(), dl.bytesDownloaded)
        dl.state = .downloading
        dl.errorMessage = nil
        activeDownloads[id] = dl
        task.resume()
    }

    public func cancelDownload(id: String) {
        if let task = tasksByID.removeValue(forKey: id) {
            idByTaskIdentifier.removeValue(forKey: task.taskIdentifier)
            task.cancel()
        }
        resumeDataByID.removeValue(forKey: id)
        lastSampleByID.removeValue(forKey: id)
        activeDownloads.removeValue(forKey: id)
    }

    public nonisolated static func computeSHA256Prefix(for fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        // Hash first 8 MB + file size for fast verification without stalling iPad storage on multi-GB files.
        if let head = try? handle.read(upToCount: 8 * 1024 * 1024) {
            hasher.update(data: head)
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int64 {
            var le = size.littleEndian
            hasher.update(data: Data(bytes: &le, count: MemoryLayout<Int64>.size))
        }
        let digest = hasher.finalize()
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

extension ModelDownloadManager: URLSessionDownloadDelegate {
    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let id = self.idByTaskIdentifier[taskID],
                  var dl = self.activeDownloads[id] else { return }
            let now = Date()
            if let sample = self.lastSampleByID[id] {
                let dt = now.timeIntervalSince(sample.date)
                if dt >= 0.4 {
                    dl.bytesPerSecond = Double(max(0, totalBytesWritten - sample.bytes)) / dt
                    self.lastSampleByID[id] = (now, totalBytesWritten)
                }
            }
            dl.bytesDownloaded = totalBytesWritten
            dl.totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : dl.totalBytes
            self.activeDownloads[id] = dl
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Must move the temporary file synchronously before returning from this delegate callback.
        let tempDest = storagePaths.tempDirectory.appendingPathComponent("dl-\(UUID().uuidString).gguf")
        let moveError: Error?
        do {
            try FileManager.default.createDirectory(at: storagePaths.tempDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: tempDest.path) {
                try FileManager.default.removeItem(at: tempDest)
            }
            try FileManager.default.moveItem(at: location, to: tempDest)
            moveError = nil
        } catch {
            moveError = error
        }

        let taskID = downloadTask.taskIdentifier
        Task { @MainActor in
            guard let id = self.idByTaskIdentifier.removeValue(forKey: taskID) else {
                try? FileManager.default.removeItem(at: tempDest)
                return
            }
            self.tasksByID.removeValue(forKey: id)
            guard var dl = self.activeDownloads[id] else {
                try? FileManager.default.removeItem(at: tempDest)
                return
            }

            if let moveError {
                dl.state = .failed
                dl.errorMessage = "Could not save downloaded file: \(moveError.localizedDescription)"
                self.activeDownloads[id] = dl
                return
            }

            dl.state = .verifying
            self.activeDownloads[id] = dl

            let finalURL = self.storagePaths.localModelsDirectory.appendingPathComponent(dl.filename)
            do {
                try FileManager.default.createDirectory(at: self.storagePaths.localModelsDirectory, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: tempDest, to: finalURL)
                let shaPrefix = Self.computeSHA256Prefix(for: finalURL)
                dl.state = .completed
                dl.bytesDownloaded = dl.totalBytes > 0 ? dl.totalBytes : dl.bytesDownloaded
                self.activeDownloads[id] = dl
                self.onDownloadCompleted?(finalURL, dl.name, dl.sourceURL.absoluteString, shaPrefix)
                // Remove completed indicator shortly after registration
                self.activeDownloads.removeValue(forKey: id)
            } catch {
                try? FileManager.default.removeItem(at: tempDest)
                dl.state = .failed
                dl.errorMessage = error.localizedDescription
                self.activeDownloads[id] = dl
            }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        // Ignore user-initiated pause/cancel errors.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return
        }
        let taskID = task.taskIdentifier
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let desc = SecretRedactor.redact(error.localizedDescription)

        Task { @MainActor in
            guard let id = self.idByTaskIdentifier.removeValue(forKey: taskID) else { return }
            self.tasksByID.removeValue(forKey: id)
            if let resumeData {
                self.resumeDataByID[id] = resumeData
            }
            if var dl = self.activeDownloads[id] {
                dl.state = .failed
                dl.bytesPerSecond = 0
                dl.errorMessage = desc
                self.activeDownloads[id] = dl
            }
        }
    }
}
