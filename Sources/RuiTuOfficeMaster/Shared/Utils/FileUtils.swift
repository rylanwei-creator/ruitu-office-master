import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum FileUtils {
    static func fileSize(of url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
    }
    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    /// 先完整复制到目标目录的临时文件，再以不覆盖方式提交；旧文件始终保留。
    @discardableResult
    static func safeCopy(from source: URL, to proposed: URL) throws -> URL {
        let fm = FileManager.default
        try Task.checkCancellation()
        guard source.isFileURL, proposed.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard values.isReadable == true else { throw CocoaError(.fileReadNoPermission) }
        let stage = proposed.deletingLastPathComponent().appendingPathComponent(".ruit-export-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stage) }
        try fm.copyItem(at: source, to: stage)
        try Task.checkCancellation()
        guard fileSize(of: stage) == fileSize(of: source) else { throw CocoaError(.fileReadCorruptFile) }
        for counter in 0...10000 {
            let ext = proposed.pathExtension
            let base = proposed.deletingPathExtension().lastPathComponent
            let name = counter == 0 ? proposed.lastPathComponent : base + " (\(counter))" + (ext.isEmpty ? "" : "." + ext)
            let dest = proposed.deletingLastPathComponent().appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { continue }
            do { try fm.moveItem(at: stage, to: dest); return dest }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError { continue }
        }
        throw CocoaError(.fileWriteFileExists)
    }
    static func isSupported(_ url: URL, types: [UTType]) -> Bool {
        guard url.isFileURL,
              let identifier = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
              let type = UTType(identifier) else { return false }
        return types.contains { type.conforms(to: $0) }
    }
}

struct ExportedFile: Sendable {
    let source: URL
    let destination: URL
}
struct ExportReport: Sendable {
    var savedFiles: [ExportedFile] = []
    var savedURLs: [URL] { savedFiles.map(\.destination) }
    var errors: [String] = []
    var renamedCount: Int { savedFiles.filter { $0.source.lastPathComponent != $0.destination.lastPathComponent }.count }
    var message: String {
        "已保存 \(savedFiles.count) 个文件" + (renamedCount > 0 ? "，\(renamedCount) 个重名文件已自动编号" : "")
            + (errors.isEmpty ? "" : "，\(errors.count) 个失败")
    }
}

/// 异步打开选择器，避免在 SwiftUI 状态更新期间嵌套同步模态事件循环。
@MainActor enum FileDialogs {
    static func response(to panel: NSOpenPanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
        }
    }
}

@MainActor enum ResultExporter {
    static func save(_ urls: [URL]) async -> ExportReport? {
        guard !urls.isEmpty else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "保存到这里"
        panel.message = "同名文件会自动加编号，保留已有文件。"
        guard await FileDialogs.response(to: panel) == .OK, let directory = panel.url else { return nil }
        let lease = ExportActivityLease()
        ProcessingActivity.setActive(true, owner: ObjectIdentifier(lease))
        defer { ProcessingActivity.setActive(false, owner: ObjectIdentifier(lease)) }
        let worker = Task.detached(priority: .userInitiated) { export(urls, to: directory) }
        return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
    }
    nonisolated static func export(_ urls: [URL], to directory: URL) -> ExportReport {
        var report = ExportReport()
        for url in urls {
            if Task.isCancelled { report.errors.append("保存已停止，剩余文件未保存"); break }
            do {
                let output = try FileUtils.safeCopy(from: url, to: directory.appendingPathComponent(url.lastPathComponent))
                report.savedFiles.append(ExportedFile(source: url, destination: output))
            } catch { report.errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return report
    }
    private final class ExportActivityLease {}
}

/// 缓存清理和处理任务互斥；不让清理删掉正在写入的文件。
enum ProcessingActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var owners: Set<ObjectIdentifier> = []
    static func setActive(_ active: Bool, owner: ObjectIdentifier) {
        lock.lock(); defer { lock.unlock() }
        if active { owners.insert(owner) } else { owners.remove(owner) }
    }
    static var isBusy: Bool {
        lock.lock(); defer { lock.unlock() }
        return !owners.isEmpty
    }
}
