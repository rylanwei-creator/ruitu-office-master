import Foundation

struct RToolAIMockService: RToolAIResponding, RToolAITaskSimulating {
    var replyDelay: Duration = .milliseconds(700)
    var stepDelay: Duration = .milliseconds(600)

    func reply(to request: RToolAIRequest) async throws -> RToolAIReply {
        try await Task.sleep(for: replyDelay)
        try Task.checkCancellation()
        let intent = request.intent ?? inferIntent(request.text)
        if let intent {
            let names = request.attachments.isEmpty ? ["示例文件（未添加附件）"] : request.attachments.map(\.name)
            let plan = RToolAITaskPlan(id: UUID(), intent: intent, sourceNames: names)
            return .init(text: "我已准备一份\(intent.title)的演示方案。请核对步骤与文件清单，再确认模拟执行。", task: plan)
        }
        return .init(text: "收到你的需求：\n“\(request.text)”\n\n这里是 Rito AI 办公模式的交互预览。我可以演示整理文件、提取文字、文档摘要和任务规划的流程。选一个快捷指令，或继续描述你想做的事。\n\n这是一条模拟回复，不代表真实分析结果。", task: nil)
    }

    func stream(to request: RToolAIRequest,
                delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
        let result = try await reply(to: request)
        let characters = Array(result.text)
        for start in stride(from: 0, to: characters.count, by: 3) {
            try Task.checkCancellation()
            await delta(String(characters[start..<min(start + 3, characters.count)]))
            // Zero-delay fixtures remain deterministic and fast.
            if replyDelay != .zero { try await Task.sleep(for: .milliseconds(65)) }
        }
        return result
    }

    func simulate(_ plan: RToolAITaskPlan,
                  progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [RToolAIResult] {
        for step in 1...3 {
            try await Task.sleep(for: stepDelay)
            try Task.checkCancellation()
            await progress(Double(step) / 3)
        }
        return plan.sourceNames.map { name in
            let detail: String
            switch plan.intent {
            case .pdfDocument: detail = "示例方案：确认页码范围或文件顺序 → 处理 PDF → 检查页数。未读取或生成 PDF。"
            case .organize: detail = "模拟去向：整理结果 / \(category(for: name)) / \(name)"
            case .extractText: detail = "示例文字：这里将显示这张图片的识别结果。未读取或识别图片。"
            case .summarize: detail = "示例摘要：概括主要内容，列出关键信息与下一步待办。未解析文档。"
            case .plan: detail = "示例计划：确认材料 → 处理文件 → 检查结果 → 导出归档。"
            }
            return RToolAIResult(sourceName: name, detail: detail)
        }
    }

    private func inferIntent(_ text: String) -> RToolAIIntent? {
        if text.contains("整理") || text.contains("分类") { return .organize }
        if text.lowercased().contains("pdf") { return .pdfDocument }
        if text.contains("识别") || text.contains("提取") || text.lowercased().contains("ocr") { return .extractText }
        if text.contains("总结") || text.contains("摘要") { return .summarize }
        if text.contains("规划") || text.contains("计划") { return .plan }
        return nil
    }

    private func category(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "tiff", "webp": "图片"
        case "pdf", "doc", "docx", "txt", "xlsx", "pptx": "文档"
        case "mp4", "mov": "视频"
        case "mp3", "wav", "m4a": "音频"
        default: "其他"
        }
    }
}
