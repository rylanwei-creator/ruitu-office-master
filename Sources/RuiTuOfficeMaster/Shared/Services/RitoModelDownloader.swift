import Foundation

private final class RitoDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    let destination: URL
    let expected: Int64
    let progress: @Sendable (Int64) -> Void
    init(destination: URL, expected: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination; self.expected = expected; self.progress = progress
    }
    func fetch(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 3600
                config.httpCookieStorage = nil; config.urlCache = nil
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url); self.task = task
                lock.unlock(); task.resume()
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock(); task?.cancel()
    }
    private func finish(_ result: Result<URL, Error>) {
        lock.lock(); let continuation = continuation; self.continuation = nil; let session = session; self.session = nil; self.task = nil; lock.unlock()
        continuation?.resume(with: result); session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > expected { finish(.failure(RitoModelError.download)); return }
        progress(totalBytesWritten)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) == expected else { throw RitoModelError.download }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { lock.lock(); let wasCancelled = cancelled; lock.unlock(); finish(.failure(wasCancelled ? CancellationError() : error)) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

enum RitoModelDownloader {
    static func download(store: RitoModelStore, manifest: RitoModelManifest, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        try store.prepare()
        var completed: Int64 = 0
        for entry in manifest.files {
            try Task.checkCancellation()
            if (try? store.verify(entry)) != nil { completed += entry.bytes; await progress(Double(completed) / Double(manifest.totalBytes)); continue }
            let stage = store.directory.appendingPathComponent(".download-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            let base = completed
            let bridge = RitoDownload(destination: stage, expected: entry.bytes) { written in
                Task { @MainActor in progress(Double(base + written) / Double(manifest.totalBytes)) }
            }
            let url = URL(string: "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(entry.name)")!
            let file = try await bridge.fetch(url)
            try Task.checkCancellation()
            guard try RitoModelStore.hash(file) == entry.sha256 else { throw RitoModelError.corrupt(entry.name) }
            let final = store.directory.appendingPathComponent(entry.name)
            if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
            try FileManager.default.moveItem(at: file, to: final)
            completed += entry.bytes; await progress(Double(completed) / Double(manifest.totalBytes))
        }
        try store.verify(manifest); await progress(1)
    }
}
