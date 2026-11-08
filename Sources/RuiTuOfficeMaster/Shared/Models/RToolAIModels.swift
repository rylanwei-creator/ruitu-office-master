import Foundation

enum RitoReplySource: String, Codable, Sendable { case mock, local, custom, cloud }

struct AIProviderCapabilities: Sendable, Equatable {
    var multiTurn = true
    var streaming = true
    var cancellation = true
    var offline = false
    var toolPlans = false
}

struct RToolAIAttachment: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let name: String
    let byteCount: Int64
    var isDirectory: Bool? = nil
    var previewData: Data? = nil
    // Only a bounded thumbnail is persisted, never the original image or its path.
}

enum RToolAIIntent: String, CaseIterable, Identifiable, Codable, Sendable {
    case organize, pdfDocument, extractText, summarize, plan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .organize: "智能整理文件"
        case .pdfDocument: "PDF 文档处理"
        case .extractText: "图片文字识别"
        case .summarize: "AI 文档助手"
        case .plan: "规划办公任务"
        }
    }
    var symbol: String {
        switch self {
        case .organize: "folder.badge.gearshape"
        case .pdfDocument: "doc.richtext"
        case .extractText: "text.viewfinder"
        case .summarize: "doc.text"
        case .plan: "checklist"
        }
    }
    var detail: String {
        switch self {
        case .organize: "按类型复制整理，保留源文件"
        case .pdfDocument: "合并 PDF，先预览顺序与页数"
        case .extractText: "逐图展示文字与对应来源"
        case .summarize: "粘贴文字，提炼要点与待办"
        case .plan: "拆解步骤，安排下一步工作"
        }
    }
    var prompt: String {
        switch self {
        case .organize: "帮我按文件类型整理附件，先给我确认方案。"
        case .pdfDocument: "按附件顺序合并这些 PDF，先给我确认方案。"
        case .extractText: "帮我提取图片中的文字，按每张图片分别展示。"
        case .summarize: "帮我总结下面粘贴的文字，列出重点和待办事项。"
        case .plan: "帮我规划今天的办公任务，列出清晰的执行步骤。"
        }
    }
}

enum RToolAITaskState: String, Equatable, Codable, Sendable {
    case awaitingConfirmation, running, completed, cancelled, failed
}

struct RToolAIResult: Identifiable, Equatable, Codable, Sendable {
    var id = UUID()
    let sourceName: String
    let detail: String
    var previewData: Data? = nil
    var fileReference: RitoResultFile? = nil
    var organizationCategory: String? = nil
    var organizationPhase: OrganizerPhase? = nil
    var renameRecovery: RenameMove? = nil
    var failed: Bool? = nil
}

struct RToolAITaskPlan: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let intent: RToolAIIntent
    var sourceNames: [String]
    var state: RToolAITaskState = .awaitingConfirmation
    var progress: Double = 0
    var results: [RToolAIResult] = []
    var error: String?
    var liveCall: RitoToolCall? = nil
    var previewReady: Bool? = nil
    var previewSummary: [String]? = nil
    var outputLocation: URL? = nil
    var taskPreviewData: Data? = nil
    var title: String { (liveCall.map { ToolRegistry.lookup($0.operation).name } ?? intent.title) + (liveCall == nil ? " · 模拟任务" : " · 本机任务") }
    var steps: [String] {
        if let liveCall { return liveCall.operation.steps }
        return switch intent {
        case .organize: ["查看文件清单", "生成分类方案", "展示每个文件的模拟去向"]
        case .pdfDocument: ["查看 PDF 清单", "确认合并或拆分方案", "展示示例处理计划"]
        case .extractText: ["查看图片清单", "模拟逐图识别", "按来源展示示例文字"]
        case .summarize: ["查看文档清单", "模拟提取要点", "展示示例摘要与待办"]
        case .plan: ["确认目标", "拆解工作步骤", "展示示例计划"]
        }
    }
}

struct RToolAIMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant }
    let id: UUID
    let role: Role
    var text: String
    var createdAt = Date()
    var attachments: [RToolAIAttachment] = []
    var task: RToolAITaskPlan?
    var source: RitoReplySource?
    var replyIssue: String? = nil // App status, never model-generated content.
    var applicationNotice: Bool? = nil
}

struct RToolAIRequest: Sendable {
    let messages: [RToolAIMessage]
    let text: String
    let attachments: [RToolAIAttachment]
    let intent: RToolAIIntent?
    var toolInstructions: String? = nil
    var progress: (@MainActor @Sendable (RitoConnectionPhase) -> Void)? = nil
    var expectsToolPlan = false
    var continuesAttachmentTask = false
}

enum RitoConnectionPhase: Sendable {
    case authorizing, connecting, reconnecting, recoveringEmptyReply, repairingPlan, receiving, waitingForModel, reasoning
    var title: String {
        switch self {
        case .authorizing: "正在读取本机密钥；如有 macOS 授权窗口，请本人确认…"
        case .connecting: "正在连接 AI 服务，等待响应…"
        case .reconnecting: "连接暂时中断，正在自动重新连接（1/1）…"
        case .recoveringEmptyReply: "服务返回了空回复，正在尝试兼容生成（1/1）…"
        case .repairingPlan: "AI 已回复，正在自动修正工具方案（1/1）…"
        case .receiving: "服务已响应，正在等待回复内容…"
        case .waitingForModel: "AI 服务仍在排队，尚未开始返回正文…"
        case .reasoning: "模型正在推理，尚未返回最终回答…"
        }
    }
}

struct RToolAIReply: Sendable {
    let text: String
    let task: RToolAITaskPlan?
    var applicationNotice = false
}

/// API integration boundary. The UI depends on this contract, not on a provider SDK.
protocol AIProvider: Sendable {
    var source: RitoReplySource { get }
    var capabilities: AIProviderCapabilities { get }
    func reply(to request: RToolAIRequest) async throws -> RToolAIReply
    func stream(to request: RToolAIRequest,
                delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply
}

// Keep the established UI/test boundary; providers implement one protocol, not two workspaces.
typealias RToolAIResponding = AIProvider

extension RToolAIResponding {
    var source: RitoReplySource { .mock }
    var capabilities: AIProviderCapabilities { .init() }
    // Existing non-streaming providers remain compatible; a future API can override this.
    func stream(to request: RToolAIRequest,
                delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
        let result = try await reply(to: request)
        try Task.checkCancellation()
        await delta(result.text)
        return result
    }
}

/// A separate boundary for future confirmation-based execution. Currently simulation only.
protocol RToolAITaskSimulating: Sendable {
    func simulate(_ plan: RToolAITaskPlan,
                  progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [RToolAIResult]
}

/// Local history stores text, thumbnails and generated-result references, never original file bytes.
struct RitoAIConversation: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var messages: [RToolAIMessage]
    var updatedAt: Date
    var customTitle: String?
    var title: String { customTitle ?? String((messages.first(where: { $0.role == .user })?.text ?? "新对话").prefix(36)) }
}

@MainActor
struct RitoAIHistoryStore {
    let defaults: UserDefaults
    private let key = "ritoAI.chatHistory.v1"
    static func local() -> Self { Self(defaults: .standard) }
    func load() -> [RitoAIConversation] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([RitoAIConversation].self, from: data) else { return [] }
        var seen: Set<UUID> = []
        return decoded.filter { !$0.messages.isEmpty && seen.insert($0.id).inserted }.prefix(30).map { original in
            var conversation = original
            for i in conversation.messages.indices where conversation.messages[i].task?.state == .running {
                conversation.messages[i].task?.state = .cancelled
            }
            for i in conversation.messages.indices where conversation.messages[i].task?.liveCall != nil {
                conversation.messages[i].task?.previewReady = false
            }
            return conversation
        }
    }
    func save(_ conversations: [RitoAIConversation]) {
        guard let data = try? JSONEncoder().encode(Array(conversations.prefix(30))) else { return }
        defaults.set(data, forKey: key)
    }
}
