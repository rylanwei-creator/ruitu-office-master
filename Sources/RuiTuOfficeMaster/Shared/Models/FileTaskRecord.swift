import Foundation

enum FileTaskState: String, Codable, Sendable {
    case waiting, running, completed, partial, failed, cancelled, interrupted
    var isActive: Bool { self == .waiting || self == .running }
    var title: String {
        switch self {
        case .waiting: return "等待处理"
        case .running: return "正在处理"
        case .completed: return "处理完成"
        case .partial: return "部分失败"
        case .failed: return "处理失败"
        case .cancelled: return "已停止"
        case .interrupted: return "上次运行中断"
        }
    }
}

struct FileTaskOutput: Codable, Sendable {
    let url: URL
    let inputSize: Int64
    let outputSize: Int64
}

struct FileTaskEntry: Identifiable, Codable, Sendable {
    let id: UUID
    let source: URL
    var state: FileTaskState = .waiting
    var output: FileTaskOutput?
    var savedURL: URL?
    var error: String?
    var attempts = 0
    init(source: URL) { id = UUID(); self.source = source }
}

struct FileTaskRecord: Identifiable, Codable, Sendable {
    let id: UUID
    let tool: String
    let configuration: String
    let createdAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var state: FileTaskState = .waiting
    var cancellationRequested = false
    var files: [FileTaskEntry]
    var succeeded: Int { files.filter { $0.state == .completed }.count }
    var failed: Int { files.filter { $0.state == .failed }.count }
    var unfinished: Int { files.count - succeeded - failed }
    /// 只计算真实处理过的项；取消剩余文件不等于处理至 100%。
    var progress: Double { files.isEmpty ? 0 : Double(succeeded + failed) / Double(files.count) }
    var currentFile: String { files.first { $0.state == .running }?.source.lastPathComponent ?? state.title }
    var summary: String {
        "\(state.title)：\(succeeded) 个成功，\(failed) 个失败" + (unfinished > 0 ? "，\(unfinished) 个未完成" : "")
    }
    var retryCount: Int { files.filter { $0.state == .failed || $0.state == .cancelled }.count }
    init(tool: String, configuration: String, sources: [URL]) {
        id = UUID(); self.tool = tool; self.configuration = configuration; createdAt = Date()
        files = sources.map(FileTaskEntry.init)
    }
}
