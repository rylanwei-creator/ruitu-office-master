import Foundation
import CoreGraphics
import UniformTypeIdentifiers

struct ImportedImage: Sendable {
    let url: URL
    let size: Int64
    let dimensions: CGSize
    let typeIdentifier: String
}
struct ImageImportReport: Sendable {
    var images: [ImportedImage] = []
    var warnings: [String] = []
    var duplicates = 0
    var message: String? { warnings.isEmpty ? nil : warnings.joined(separator: "\n") }
}

/// 图片工具共用导入校验；文件夹递归扫描在后台进行，不跟随目录符号链接。
enum ImageFileImporter {
    static func collect(_ urls: [URL], excluding: [URL] = [], limit: Int = 10_000) throws -> ImageImportReport {
        let fm = FileManager.default
        var report = ImageImportReport()
        var seen = Set(excluding.map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        var identities = Set<String>()
        func identity(_ url: URL) -> String? {
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let device = attrs[.systemNumber] as? NSNumber, let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
            return "\(device):\(inode)"
        }
        for url in excluding { if let key = identity(url) { identities.insert(key) } }
        var visitedFolders = Set<String>()
        var stack = urls.reversed().map { ($0, false) }
        var scanned = 0
        func warn(_ message: String) { if report.warnings.count < 30 { report.warnings.append(message) } }
        while let (raw, fromFolder) = stack.popLast() {
            try Task.checkCancellation()
            scanned += 1
            guard scanned <= limit else { warn("本次最多扫描 \(limit) 个项目，其余未导入；请缩小文件夹范围。"); break }
            guard raw.isFileURL else { warn("仅支持本机文件：\(raw.lastPathComponent)"); continue }
            do {
                let values = try raw.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                if values.isDirectory == true {
                    let package = (try? raw.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? ["app", "bundle", "framework", "photoslibrary", "pages", "numbers", "key", "rtfd"].contains(raw.pathExtension.lowercased())
                    if values.isSymbolicLink == true || package { continue }
                    let key = raw.standardizedFileURL.resolvingSymlinksInPath().path
                    guard visitedFolders.insert(key).inserted else { continue }
                    let children = try fm.contentsOfDirectory(at: raw, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    stack.append(contentsOf: children.reversed().map { ($0, true) })
                    continue
                }
                let url = raw.standardizedFileURL.resolvingSymlinksInPath()
                guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                    warn("不是普通图片文件：\(raw.lastPathComponent)"); continue
                }
                guard !seen.contains(url.path) else { report.duplicates += 1; continue }
                let key = identity(url)
                if let key, identities.contains(key) { report.duplicates += 1; continue }
                guard fm.isReadableFile(atPath: url.path) else { warn("无法读取：\(raw.lastPathComponent)"); continue }
                // 递归文件夹中忽略非图片；显式选择的不支持文件给出原因。
                if fromFolder, (try? ImageCodec.sourceType(at: url)) == nil {
                    if ["jpg", "jpeg", "png", "heic", "heif", "webp", "bmp", "tif", "tiff"].contains(url.pathExtension.lowercased()) { warn("无法读取图片：\(raw.lastPathComponent)") }
                    continue
                }
                let type = try ImageCodec.sourceType(at: url)
                guard ImageCompressionService.supportedFormats.contains(where: { type.conforms(to: $0) }) else {
                    warn("不支持的图片格式：\(raw.lastPathComponent)"); continue
                }
                try ImageCodec.validateStaticImage(at: url)
                let dimensions = try ImageCodec.dimensions(at: url)
                report.images.append(ImportedImage(url: url, size: FileUtils.fileSize(of: url), dimensions: dimensions, typeIdentifier: type.identifier))
                seen.insert(url.path)
                if let key { identities.insert(key) }
            } catch {
                if error is CancellationError { throw error }
                warn("\(raw.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        if report.images.isEmpty && report.warnings.isEmpty && report.duplicates == 0 { warn("没有找到支持的静态图片。") }
        return report
    }
    static func collectInBackground(_ urls: [URL], excluding: [URL]) async throws -> ImageImportReport {
        let worker = Task.detached(priority: .userInitiated) { try collect(urls, excluding: excluding) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}
