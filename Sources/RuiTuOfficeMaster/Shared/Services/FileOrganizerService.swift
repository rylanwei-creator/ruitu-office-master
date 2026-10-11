import Foundation
import CryptoKit

struct OrganizerJournalStore: Sendable {
    let directory: URL
    static var standard: Self {
        let base = ProcessInfo.processInfo.environment["RUITU_WORK_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RuiTuOfficeMaster")
        return Self(directory: base.appendingPathComponent("OrganizerLogs"))
    }
    func save(_ journal: OrganizerJournal) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(journal).write(to: directory.appendingPathComponent(journal.id.uuidString + ".json"), options: .atomic)
    }
    func deleteRecord(_ id: UUID) throws {
        // Only the selected journal is removed; source and output paths are never used here.
        try FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".json"))
    }
    func recent() throws -> [OrganizerJournal] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        return try urls.prefix(20).map { try JSONDecoder().decode(OrganizerJournal.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }
}

enum FileOrganizerService {
    private static var fm: FileManager { FileManager() }
    // Foundation enumerators can return /private/var while picker URLs use /var.
    // Resolve an existing ancestor so comparisons also remain stable after a move.
    private static func comparablePath(_ url: URL) -> String {
        var ancestor = url.standardizedFileURL
        var components: [String] = []
        while !fm.fileExists(atPath: ancestor.path) && ancestor.path != "/" {
            components.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
        var result = ancestor.resolvingSymlinksInPath().path
        for component in components.reversed() { result = (result as NSString).appendingPathComponent(component) }
        return result.precomposedStringWithCanonicalMapping
    }
    static func within(_ url: URL, _ parent: URL) -> Bool {
        let a = comparablePath(url), b = comparablePath(parent)
        return a == b || a.hasPrefix(b == "/" ? "/" : b + "/")
    }
    private static func key(_ url: URL) -> String { comparablePath(url).lowercased() }
    private static func occupied(_ url: URL) throws -> Bool {
        let parent = url.deletingLastPathComponent()
        return try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil).contains { key($0) == key(url) }
    }
    static func category(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let groups: [(String, Set<String>)] = [
            ("图片", ["jpg","jpeg","png","heic","heif","gif","bmp","tif","tiff","webp","avif","svg","ico","raw","dng","psd"]),
            ("文档", ["pdf","doc","docx","xls","xlsx","ppt","pptx","txt","rtf","csv","pages","numbers","key","odt","ods","odp","epub"]),
            ("视频", ["mp4","mov","m4v","avi","mkv","webm","flv","wmv","mpeg","mpg","ts"]),
            ("音频", ["mp3","wav","m4a","aac","flac","ogg","aiff","aif","alac","opus"]),
            ("压缩包", ["zip","rar","7z","tar","gz","bz2","xz","dmg","iso"]),
            ("代码", ["swift","py","js","ts","jsx","tsx","html","css","json","xml","yaml","yml","sh","c","h","cpp","java","sql","md"])
        ]
        return groups.first { $0.1.contains(ext) }?.0 ?? "其他"
    }
    static func noLinks(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL.path == url.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw OrganizerError.message("路径已变化或包含符号链接，请重新选择：\(url.path)")
        }
    }
    static func hash(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try h.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func preview(_ configuration: OrganizerConfiguration, limit: Int = 10_000,
                        progress: @Sendable (Int) -> Void = { _ in }) throws -> OrganizerPlan {
        guard !configuration.roots.isEmpty, limit > 0, configuration.destination.isFileURL else { throw OrganizerError.message("请选择源文件夹和整理位置。") }
        try noLinks(configuration.destination)
        var c = configuration
        c.roots = Array(Set(c.roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() })).sorted { $0.path < $1.path }
        c.excluded = c.excluded.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
        c.destination = c.destination.standardizedFileURL
        guard !c.roots.contains(where: { within($0, c.destination) }) else { throw OrganizerError.message("整理位置不能与源文件夹相同，也不能是其上级文件夹。请选择独立文件夹或源文件夹里的“整理结果”。") }
        var anchor = c.destination
        while !fm.fileExists(atPath: anchor.path) { anchor.deleteLastPathComponent() }
        try noLinks(anchor)
        let anchorID = try OrganizerDirectoryIdentity.read(anchor)
        var sources: [(URL, OrganizerStamp)] = [], identities = Set<String>(), visited = Set<String>()
        var scanned = 0, skipped = 0, warnings: [String] = []
        func warn(_ text: String) { if warnings.count < 20 { warnings.append(text) } }
        for root in c.roots {
            try Task.checkCancellation(); try noLinks(root); _ = try OrganizerDirectoryIdentity.read(root)
            if c.excluded.contains(where: { within(root, $0) }) { skipped += 1; continue }
            if visited.contains(root.path) { continue }
            var readError: Error?
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.isPackageKey], options: [.skipsHiddenFiles,.skipsPackageDescendants], errorHandler: { url, error in
                // Read errors must invalidate the plan rather than silently leaving a folder unprocessed.
                readError = OrganizerError.message("无法扫描 \(url.path)：\(error.localizedDescription)"); return false
            }) else { throw OrganizerError.message("无法扫描：\(root.path)") }
            visited.insert(root.path)
            for case let url as URL in e {
                try Task.checkCancellation(); scanned += 1
                guard scanned <= limit else { throw OrganizerError.message("扫描超过 \(limit) 个项目，请缩小范围或添加排除文件夹后重试。本次未生成可执行预览。") }
                if scanned % 50 == 0 { progress(scanned) }
                if within(url, c.destination) || c.excluded.contains(where: { within(url, $0) }) { e.skipDescendants(); skipped += 1; continue }
                let values = try url.resourceValues(forKeys: [.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey,.isPackageKey])
                if values.isSymbolicLink == true || values.isPackage == true { e.skipDescendants(); skipped += 1; continue }
                if values.isDirectory == true {
                    if !c.recursive { e.skipDescendants() }
                    else { visited.insert(url.path) }
                    continue
                }
                guard values.isRegularFile == true else { skipped += 1; continue }
                try noLinks(url); let stamp = try OrganizerStamp.read(url)
                if !identities.insert("\(stamp.device):\(stamp.inode)").inserted { skipped += 1; continue }
                sources.append((url, stamp))
            }
            if let readError { throw readError }
        }
        sources.sort { $0.0.path < $1.0.path }
        var reserved = Set<String>(), existing: [String: Set<String>] = [:], items: [OrganizerItem] = []
        for (url, stamp) in sources {
            try Task.checkCancellation()
            let group = category(url), dir = c.destination.appendingPathComponent(group)
            try noLinks(dir)
            if existing[dir.path] == nil {
                if fm.fileExists(atPath: dir.path) {
                    _ = try OrganizerDirectoryIdentity.read(dir)
                    existing[dir.path] = Set(try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).map(key))
                } else { existing[dir.path] = [] }
            }
            var dest = dir.appendingPathComponent(url.lastPathComponent), conflict = false
            for number in 0...10000 {
                let occupied = reserved.contains(key(dest)) || existing[dir.path]!.contains(key(dest))
                if !occupied { reserved.insert(key(dest)); break }
                if c.conflict == .skip { conflict = true; break }
                guard number < 10000 else { throw OrganizerError.message("无法为 \(url.lastPathComponent) 分配目标名称。") }
                let ext = url.pathExtension, suffix = " (\(number + 1))" + (ext.isEmpty ? "" : "." + ext)
                var base = url.deletingPathExtension().lastPathComponent
                while (base + suffix).utf8.count > 255 && !base.isEmpty { base.removeLast() }
                guard !base.isEmpty else { throw OrganizerError.message("目标文件名过长。") }
                dest = dir.appendingPathComponent(base + suffix)
            }
            var item = OrganizerItem(id: UUID(), source: url, destination: dest, category: group, sourceStamp: stamp)
            if conflict { item.phase = .skipped; item.message = "目标名称已占用，按设置跳过。" }
            items.append(item)
        }
        if skipped > 0 { warn("已排除 \(skipped) 个目录、链接、特殊文件或重复路径；目标目录不会被重新扫描。隐藏项与应用包不参与整理。") }
        progress(scanned)
        return OrganizerPlan(configuration: c, anchor: anchor, anchorIdentity: anchorID, items: items, skippedCount: skipped, warnings: warnings)
    }
    private static func directories(_ url: URL) throws {
        try noLinks(url)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try noLinks(url); _ = try OrganizerDirectoryIdentity.read(url)
    }
    private static func assertFile(_ url: URL, stamp: OrganizerStamp, digest: String? = nil) throws {
        try noLinks(url)
        guard try OrganizerStamp.read(url) == stamp else { throw OrganizerError.message("文件已修改、替换或删除：\(url.path)") }
        if let digest, try hash(url) != digest { throw OrganizerError.message("文件内容已变化，已保留：\(url.path)") }
        guard try OrganizerStamp.read(url) == stamp else { throw OrganizerError.message("核对期间文件已变化：\(url.path)") }
    }
    static func execute(_ plan: OrganizerPlan, store: OrganizerJournalStore,
                        progress: @Sendable (Int, String) -> Void = { _, _ in }) throws -> OrganizerJournal {
        try Task.checkCancellation(); try noLinks(plan.anchor)
        guard try OrganizerDirectoryIdentity.read(plan.anchor) == plan.anchorIdentity else { throw OrganizerError.message("整理位置已被替换，请重新生成预览。") }
        var journal = OrganizerJournal(id: UUID(), date: Date(), configuration: plan.configuration, items: plan.items)
        try store.save(journal) // A failed log write must happen before touching the user's files.
        for index in journal.items.indices where journal.items[index].phase == .pending {
            if Task.isCancelled { journal.stopped = true; break }
            let item = journal.items[index]
            var stage: URL?
            do {
                try assertFile(item.source, stamp: item.sourceStamp)
                let digest = try hash(item.source)
                try assertFile(item.source, stamp: item.sourceStamp)
                try noLinks(plan.anchor)
                guard try OrganizerDirectoryIdentity.read(plan.anchor) == plan.anchorIdentity else { throw OrganizerError.message("整理位置已被替换。") }
                try directories(item.destination.deletingLastPathComponent())
                guard try !occupied(item.destination) else { throw OrganizerError.message("目标名称在预览后被占用，请重新预览；未覆盖已有文件。") }
                let temp = item.destination.deletingLastPathComponent().appendingPathComponent(".ruit-organize-\(UUID().uuidString)")
                stage = temp
                try fm.copyItem(at: item.source, to: temp)
                guard try hash(temp) == digest else { throw OrganizerError.message("副本内容校验失败，原文件保留。") }
                try assertFile(item.source, stamp: item.sourceStamp, digest: digest)
                journal.items[index].outputStamp = try OrganizerStamp.read(temp)
                journal.items[index].digest = digest; journal.items[index].temporary = temp
                journal.items[index].phase = .prepared
                try store.save(journal)
                try Task.checkCancellation(); try noLinks(item.destination.deletingLastPathComponent())
                guard try !occupied(item.destination) else { throw OrganizerError.message("目标名称在预览后被占用，请重新预览。") }
                try fm.moveItem(at: temp, to: item.destination) // Exact preview path, never choose a different name or replace.
                stage = nil; journal.items[index].temporary = nil; journal.items[index].phase = .copied
                try store.save(journal)
                if plan.configuration.mode == .move {
                    try Task.checkCancellation()
                    try assertFile(item.destination, stamp: journal.items[index].outputStamp!, digest: digest)
                    try assertFile(item.source, stamp: item.sourceStamp, digest: digest)
                    try fm.removeItem(at: item.source)
                }
                journal.items[index].phase = .completed; journal.items[index].message = nil
                try store.save(journal)
            } catch {
                if let stage {
                    try? fm.removeItem(at: stage)
                    journal.items[index].outputStamp = nil; journal.items[index].digest = nil; journal.items[index].temporary = nil
                }
                journal.items[index].message = error is CancellationError ? "已停止；已生成的副本可通过撤销移除。" : error.localizedDescription
                // Keep copied/prepared ownership metadata so a partial operation can be safely undone.
                journal.items[index].phase = .failed
                if error is CancellationError { journal.stopped = true }
                do { try store.save(journal) }
                catch { journal.error = "操作日志保存失败，已停止：\(error.localizedDescription)"; journal.stopped = true }
            }
            progress(index + 1, item.source.lastPathComponent)
            if journal.stopped { break }
        }
        try store.save(journal)
        return journal
    }
    static func undo(_ original: OrganizerJournal, store: OrganizerJournalStore,
                     progress: @Sendable (Int, String) -> Void = { _, _ in }) throws -> OrganizerJournal {
        var journal = original; journal.error = nil; journal.stopped = false
        try store.save(journal)
        for index in journal.items.indices.reversed() where journal.items[index].canUndo {
            if Task.isCancelled { journal.stopped = true; break }
            let item = journal.items[index]
            var stage: URL?
            do {
                guard within(item.destination, journal.configuration.destination),
                      journal.configuration.roots.contains(where: { within(item.source, $0) }),
                      item.source != item.destination, let stamp = item.outputStamp, let digest = item.digest else {
                    throw OrganizerError.message("整理记录无效，未修改任何文件。")
                }
                // A crash before the prepared stage was published leaves only an app-owned temporary file.
                if !fm.fileExists(atPath: item.destination.path), let temp = item.temporary {
                    guard temp.deletingLastPathComponent() == item.destination.deletingLastPathComponent(), temp.lastPathComponent.hasPrefix(".ruit-organize-") else { throw OrganizerError.message("临时路径无效。") }
                    if fm.fileExists(atPath: temp.path) { try assertFile(temp, stamp: stamp, digest: digest); try fm.removeItem(at: temp) }
                    journal.items[index].phase = .undone; journal.items[index].message = "未提交的临时副本已清理，原文件未移动。"
                    try store.save(journal); continue
                }
                try assertFile(item.destination, stamp: stamp, digest: digest)
                if journal.configuration.mode == .move {
                    if fm.fileExists(atPath: item.source.path) {
                        if let restored = item.restoredStamp { try assertFile(item.source, stamp: restored, digest: digest) }
                        else if item.phase != .completed { try assertFile(item.source, stamp: item.sourceStamp, digest: digest) }
                        else { throw OrganizerError.message("原位置已有文件，无法撤销；两个文件均保留：\(item.source.path)") }
                    } else {
                        try noLinks(item.source.deletingLastPathComponent())
                        _ = try OrganizerDirectoryIdentity.read(item.source.deletingLastPathComponent())
                        let temp = item.source.deletingLastPathComponent().appendingPathComponent(".ruit-organize-undo-\(UUID().uuidString)")
                        stage = temp; try fm.copyItem(at: item.destination, to: temp)
                        guard try hash(temp) == digest else { throw OrganizerError.message("恢复副本校验失败，整理后的文件保留。") }
                        journal.items[index].restoredStamp = try OrganizerStamp.read(temp)
                        journal.items[index].phase = .restoring; try store.save(journal)
                        try Task.checkCancellation(); try noLinks(item.source.deletingLastPathComponent())
                        try fm.moveItem(at: temp, to: item.source); stage = nil
                        try store.save(journal)
                    }
                    try assertFile(item.source, stamp: journal.items[index].restoredStamp ?? item.sourceStamp, digest: digest)
                }
                try Task.checkCancellation(); try assertFile(item.destination, stamp: stamp, digest: digest)
                try fm.removeItem(at: item.destination)
                journal.items[index].phase = .undone; journal.items[index].message = "撤销成功"
                try store.save(journal)
            } catch {
                if let stage {
                    try? fm.removeItem(at: stage)
                    journal.items[index].restoredStamp = nil
                    journal.items[index].phase = item.phase
                }
                journal.items[index].message = "撤销未完成：\(error.localizedDescription)"
                if error is CancellationError { journal.stopped = true }
                do { try store.save(journal) }
                catch { journal.error = "操作日志保存失败，已停止：\(error.localizedDescription)"; journal.stopped = true }
            }
            progress(index + 1, item.source.lastPathComponent)
            if journal.stopped { break }
        }
        let undoErrors = journal.items.filter { $0.message?.hasPrefix("撤销未完成：") == true }.count
        if undoErrors > 0 { journal.error = "有 \(undoErrors) 项撤销未完成，文件已保留，请查看对应原因。" }
        try store.save(journal)
        return journal
    }
}
