import Foundation

enum RenameMode: String, CaseIterable, Sendable {
    case prefix = "添加前缀", suffix = "添加后缀", replace = "查找替换", numbering = "序号命名"
    var systemImage: String {
        switch self { case .prefix: return "textformat.abc"; case .suffix: return "textformat.abc.dottedunderline"; case .replace: return "arrow.triangle.swap"; case .numbering: return "list.number" }
    }
}
/// 用文件身份、大小和修改时间识别预览/撤销期间被替换或编辑的文件。
struct RenameFileVersion: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: Date
    static func read(_ url: URL) -> Self? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = values[.systemNumber] as? NSNumber, let inode = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber, let modified = values[.modificationDate] as? Date else { return nil }
        return Self(device: device.uint64Value, inode: inode.uint64Value, size: size.uint64Value, modified: modified)
    }
}
struct RenamePreviewItem: Identifiable, Sendable {
    let id = UUID()
    let originalURL: URL
    let originalName: String
    let newName: String
    let isValid: Bool
    var conflictReason: String? = nil
    var sourceVersion: RenameFileVersion? = nil
}
struct RenameMove: Sendable {
    let original: URL
    let renamed: URL
    var version: RenameFileVersion? = nil
}
enum RenameResult: Sendable {
    case success(moves: [RenameMove])
    case failure(errors: [String])
}
struct FileRenameService: Sendable {
    func generateNewName(originalName: String, mode: RenameMode, prefix: String, suffix: String,
                         findText: String, replaceText: String, numberText: String, number: Int, numberDigits: Int) -> String {
        let base = (originalName as NSString).deletingPathExtension
        let ext = (originalName as NSString).pathExtension
        let name: String
        switch mode {
        case .prefix: name = prefix + base
        case .suffix: name = base + suffix
        case .replace: name = findText.isEmpty ? base : base.replacingOccurrences(of: findText, with: replaceText)
        case .numbering:
            let value = String(number)
            name = numberText + "_" + String(repeating: "0", count: max(0, min(12, numberDigits) - value.count)) + value
        }
        return name + (ext.isEmpty ? "" : "." + ext)
    }
    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        guard let first = try? FileManager.default.attributesOfItem(atPath: a.path),
              let second = try? FileManager.default.attributesOfItem(atPath: b.path) else { return false }
        return (first[.systemFileNumber] as? NSNumber) == (second[.systemFileNumber] as? NSNumber) &&
               (first[.systemNumber] as? NSNumber) == (second[.systemNumber] as? NSNumber)
    }
    private func validName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\0") && name.utf8.count <= 255
    }
    func generatePreview(files: [URL], mode: RenameMode, prefix: String, suffix: String, findText: String,
                         replaceText: String, numberText: String, startNumber: Int, numberDigits: Int) -> [RenamePreviewItem] {
        let fm = FileManager.default
        var reserved = Set<String>()
        return files.enumerated().map { index, url in
            let (number, overflow) = startNumber.addingReportingOverflow(index)
            let requested = generateNewName(originalName: url.lastPathComponent, mode: mode, prefix: prefix, suffix: suffix,
                findText: findText, replaceText: replaceText, numberText: numberText, number: number, numberDigits: numberDigits)
            var name = requested
            var reason: String?
            let version = RenameFileVersion.read(url)
            let changed = requested != url.lastPathComponent
            if !validName(requested) || overflow { reason = "文件名无效或序号超出范围" }
            else if !fm.fileExists(atPath: url.path) { reason = "原文件已不存在" }
            else if version == nil { reason = "无法读取原文件状态，请检查权限" }
            else if !fm.isWritableFile(atPath: url.deletingLastPathComponent().path) { reason = "所在文件夹没有写入权限" }
            else if changed {
                // 编号避让在预览阶段完成，使预览与实际改名一致。
                let dir = url.deletingLastPathComponent()
                let ext = (requested as NSString).pathExtension
                let base = (requested as NSString).deletingPathExtension
                for counter in 0...10000 {
                    name = counter == 0 ? requested : base + " (\(counter))" + (ext.isEmpty ? "" : "." + ext)
                    let target = dir.appendingPathComponent(name)
                    let key = target.standardizedFileURL.path.lowercased()
                    if (!fm.fileExists(atPath: target.path) || sameFile(target, url)) && !reserved.contains(key) {
                        reserved.insert(key); break
                    }
                    if counter == 10000 { reason = "无法找到可用的目标文件名" }
                }
            }
            return RenamePreviewItem(originalURL: url, originalName: url.lastPathComponent,
                newName: name, isValid: changed && reason == nil, conflictReason: reason, sourceVersion: version)
        }
    }
    func execute(previewItems: [RenamePreviewItem], progressHandler: @escaping @Sendable (Double) -> Void) -> RenameResult {
        let fm = FileManager.default
        let problems = previewItems.compactMap { item in item.conflictReason.map { "\(item.originalName)：\($0)" } }
        guard problems.isEmpty else { return .failure(errors: problems) }
        let items = previewItems.filter(\.isValid)
        var keys = Set<String>()
        for item in items {
            let dest = item.originalURL.deletingLastPathComponent().appendingPathComponent(item.newName)
            guard validName(item.newName), fm.fileExists(atPath: item.originalURL.path),
                  item.sourceVersion == nil || RenameFileVersion.read(item.originalURL) == item.sourceVersion,
                  (!fm.fileExists(atPath: dest.path) || sameFile(dest, item.originalURL)), keys.insert(dest.path.lowercased()).inserted else {
                return .failure(errors: ["文件状态已变化，请重新预览后再执行：\(item.originalName)"])
            }
        }
        var staged: [(item: RenamePreviewItem, temporary: URL)] = []
        var completed: [RenameMove] = []
        do {
            for item in items {
                guard item.sourceVersion == nil || RenameFileVersion.read(item.originalURL) == item.sourceVersion else {
                    throw CocoaError(.fileReadUnknown)
                }
                let temp = item.originalURL.deletingLastPathComponent().appendingPathComponent(".ruit-rename-\(UUID().uuidString)")
                try fm.moveItem(at: item.originalURL, to: temp)
                staged.append((item, temp))
            }
            for entry in staged {
                let target = entry.item.originalURL.deletingLastPathComponent().appendingPathComponent(entry.item.newName)
                try fm.moveItem(at: entry.temporary, to: target)
                completed.append(RenameMove(original: entry.item.originalURL, renamed: target, version: RenameFileVersion.read(target)))
                progressHandler(Double(completed.count) / Double(max(1, items.count)))
            }
            return .success(moves: completed)
        } catch {
            var errors = ["改名未完成，正在恢复原文件名：\(error.localizedDescription)"]
            for move in completed.reversed() {
                do { try fm.moveItem(at: move.renamed, to: move.original) }
                catch { errors.append("无法恢复 \(move.original.lastPathComponent)，文件保留在：\(move.renamed.path)") }
            }
            for entry in staged where fm.fileExists(atPath: entry.temporary.path) {
                do { try fm.moveItem(at: entry.temporary, to: entry.item.originalURL) }
                catch { errors.append("无法恢复 \(entry.item.originalName)，文件保留在：\(entry.temporary.path)") }
            }
            return .failure(errors: errors)
        }
    }
    func undo(_ moves: [RenameMove]) -> RenameResult {
        let items = moves.map {
            RenamePreviewItem(originalURL: $0.renamed, originalName: $0.renamed.lastPathComponent,
                              newName: $0.original.lastPathComponent, isValid: true, sourceVersion: $0.version)
        }
        return execute(previewItems: items, progressHandler: { _ in })
    }
}
