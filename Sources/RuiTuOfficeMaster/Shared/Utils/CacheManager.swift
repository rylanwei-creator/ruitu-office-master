import Foundation

enum CacheManager {
    static let expirationInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let sessionID = UUID().uuidString
    static var rootDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["RUITU_WORK_DIRECTORY"] {
            return URL(fileURLWithPath: path).appendingPathComponent("Cache")
        }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("RuiTuOfficeMaster")
    }
    private static func category(_ name: String) -> URL {
        let dir = rootDirectory.appendingPathComponent(name).appendingPathComponent(sessionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var imageCacheDirectory: URL { category("ImageCache") }
    static var mediaCacheDirectory: URL { category("MediaCache") }
    static var documentCacheDirectory: URL { category("DocumentCache") }
    static func makeTaskDirectory(in directory: URL) throws -> URL {
        let dir = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static func isolatedDirectory(in directory: URL) -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var totalCacheSize: Int64 { directorySize(at: rootDirectory) }
    static var formattedCacheSize: String { FileUtils.formatSize(totalCacheSize) }
    static func clearAll() throws {
        guard !ProcessingActivity.isBusy else { throw CacheError.processing }
        if FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
    }
    /// 只在启动时清理过期的旧会话；当前会话中的未保存结果不会自动过期。
    static func cleanExpired() {
        let fm = FileManager.default
        for name in ["ImageCache", "MediaCache", "DocumentCache"] {
            let dir = rootDirectory.appendingPathComponent(name)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in files where url.lastPathComponent != sessionID {
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(date) > expirationInterval { try? fm.removeItem(at: url) }
            }
        }
    }
    static func cacheFileURL(in directory: URL, prefix: String, ext: String) -> URL {
        directory.appendingPathComponent("\(prefix)_\(UUID().uuidString).\(ext)")
    }
    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles) else { return 0 }
        return enumerator.reduce(0) { total, entry in
            guard let file = entry as? URL, (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return total }
            return total + FileUtils.fileSize(of: file)
        }
    }
}
enum CacheError: LocalizedError {
    case processing
    var errorDescription: String? { "有任务正在处理或保存，请完成后再清理缓存" }
}
