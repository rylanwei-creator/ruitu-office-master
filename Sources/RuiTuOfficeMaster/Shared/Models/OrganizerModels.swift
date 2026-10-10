import Foundation

enum OrganizerMode: String, CaseIterable, Codable, Sendable { case copy = "复制", move = "移动" }
enum OrganizerConflict: String, CaseIterable, Codable, Sendable { case number = "自动编号", skip = "跳过同名" }
enum OrganizerPhase: String, Codable, Sendable {
    case pending = "等待", prepared = "准备提交", copied = "副本已生成", completed = "成功"
    case failed = "失败", skipped = "跳过", undone = "已撤销", restoring = "恢复中"
}
struct OrganizerStamp: Codable, Sendable, Equatable {
    let device: UInt64, inode: UInt64, size: UInt64
    let modified: Date
    static func read(_ url: URL) throws -> Self {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              let d = a[.systemNumber] as? NSNumber, let i = a[.systemFileNumber] as? NSNumber,
              let s = a[.size] as? NSNumber, let m = a[.modificationDate] as? Date else {
            throw OrganizerError.message("只处理普通文件，符号链接和文件夹不会作为文件移动。")
        }
        return Self(device: d.uint64Value, inode: i.uint64Value, size: s.uint64Value, modified: m)
    }
}
struct OrganizerDirectoryIdentity: Codable, Sendable, Equatable {
    let device: UInt64, inode: UInt64
    static func read(_ url: URL) throws -> Self {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeDirectory,
              let d = a[.systemNumber] as? NSNumber, let i = a[.systemFileNumber] as? NSNumber else {
            throw OrganizerError.message("文件夹不可用或已被符号链接替换：\(url.path)")
        }
        return Self(device: d.uint64Value, inode: i.uint64Value)
    }
}
struct OrganizerConfiguration: Codable, Sendable, Equatable {
    var roots: [URL]
    var destination: URL
    var recursive: Bool
    var excluded: [URL]
    var mode: OrganizerMode
    var conflict: OrganizerConflict
}
struct OrganizerItem: Identifiable, Codable, Sendable {
    let id: UUID
    let source: URL, destination: URL, category: String
    let sourceStamp: OrganizerStamp
    var phase: OrganizerPhase = .pending
    var message: String? = nil
    var outputStamp: OrganizerStamp? = nil
    var digest: String? = nil
    var restoredStamp: OrganizerStamp? = nil
    var temporary: URL? = nil
    var canUndo: Bool { outputStamp != nil && phase != .undone }
}
struct OrganizerPlan: Sendable {
    let configuration: OrganizerConfiguration
    let anchor: URL
    let anchorIdentity: OrganizerDirectoryIdentity
    let items: [OrganizerItem]
    let skippedCount: Int
    let warnings: [String]
    var actionable: [OrganizerItem] { items.filter { $0.phase == .pending } }
    var totalBytes: UInt64 { actionable.reduce(0) { $0 + $1.sourceStamp.size } }
}
struct OrganizerJournal: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let configuration: OrganizerConfiguration
    var items: [OrganizerItem]
    var stopped = false
    var error: String? = nil
    var successCount: Int { items.filter { $0.phase == .completed }.count }
    var failureCount: Int { items.filter { $0.phase == .failed }.count }
    var skippedCount: Int { items.filter { $0.phase == .skipped }.count }
    var undoableCount: Int { items.filter(\.canUndo).count }
    var summary: String {
        "成功 \(successCount) · 失败 \(failureCount) · 跳过 \(skippedCount) · 已撤销 \(items.filter { $0.phase == .undone }.count)"
            + (stopped ? " · 已停止，未完成项保留" : "")
    }
}
enum OrganizerError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}
