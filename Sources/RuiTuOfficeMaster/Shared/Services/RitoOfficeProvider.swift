import Foundation

struct RitoOfficeProvider: AIProvider {
    let underlying: any AIProvider
    var planningTimeout: TimeInterval = 120
    var source: RitoReplySource { underlying.source }
    var capabilities: AIProviderCapabilities { var result = underlying.capabilities; result.toolPlans = true; return result }
    func reply(to request: RToolAIRequest) async throws -> RToolAIReply { try await stream(to: request) { _ in } }
    func stream(to request: RToolAIRequest, delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
        guard !request.attachments.isEmpty else {
            var request = request
            request.toolInstructions = "已注册工具：" + ToolRegistry.tools.map(\.name).joined(separator:"、") + "。实际处理需要用户添加附件、核对参数、预览并确认。不具备任意Shell、任意文件路径、删除或覆盖能力。"
            return try await underlying.stream(to:request,delta:delta)
        }
        let files = request.attachments.map { ["id": $0.id.uuidString, "type": $0.isDirectory == true ? "directory" : ($0.name as NSString).pathExtension.lowercased()] }
        let list = String(decoding: try JSONSerialization.data(withJSONObject: files), as: UTF8.self)
        let exampleIDs = String(decoding:try JSONSerialization.data(withJSONObject:request.attachments.map { $0.id.uuidString }),as:UTF8.self)
        let followUp = request.continuesAttachmentTask
            ? "\n本轮沿用当前会话已授权的附件。结合原任务和追问理解用户补充；同意默认值或参数已足够时直接返回可预览方案，无需重传。用户取消或转问无关问题时不生成任务。"
            : ""
        let clarification = source == .local
            ? "普通问题、需澄清时task:null。未知参数省略或留空，禁止占位文字。"
            : "用户只是问问题、需要澄清、附件类型或数量不符时，返回 {\"message\":\"正常回答或具体追问\",\"task\":null}，不要硬造工具任务。未确定的参数省略或填空字符串，绝不要填“待用户补充”等占位文字。参数值必须使用清单中的枚举与数值范围。following不要填null参数。PDF拆分、证件照、去水印每次1个文件；PDF合并至少2个PDF；拼图2至8张图片。文件太多时应询问选择，不能擅自忽略附件。"
        let toolQuery = request.continuesAttachmentTask ? (request.messages.first?.text ?? "") + "\n" + request.text : request.text
        let instruction = """
        注册工具与参数：\(source == .local ? ToolRegistry.localPrompt(for:request.attachments,text:toolQuery) : ToolRegistry.prompt(for: request.attachments))
        当前附件可直接使用：\(ToolRegistry.recommended(for:request.attachments).map(\.id).joined(separator:","))。其他工具仅在后续输入类型匹配时使用。
        可用附件（只含ID与类型）：\(list)\(followUp)
        只返回JSON：{"message":"中文方案说明","task":{"operation":"注册ID","attachmentIDs":\(exampleIDs),"parameters":{"参数名":"字符串值"},"following":[{"operation":"下一步注册ID","parameters":{}}]}}。attachmentIDs只能从这些实际ID中原样选取，不能写文件名或重新生成ID。
        仅使用已注册工具和清单ID；parameters按注册参数，数值也用字符串。following可省略，最多3步，每步使用上一步新生成文件。不支持的需求task:null。不得提供路径、命令、密码、regionConfirmed或任意其他字段。
        \(clarification)
        用户明确指定的设置必须写入对应参数，不能只在说明中提到。PDF密码和图片修补选区需在本机确认。移动/改名改变原路径；默认输出新文件不覆盖。尚未执行，不能声称成功。
        """
        let prepared = RToolAIRequest(messages: request.messages, text: request.text, attachments: [], intent: request.intent, toolInstructions: instruction,progress:request.progress,expectsToolPlan:true,continuesAttachmentTask:request.continuesAttachmentTask)
        let announcement = await RitoPlanAnnouncement()
        return try await RitoAsyncDeadline.run(seconds: planningTimeout) {
            let responder: any AIProvider
            if let credentialProvider = underlying as? RitoCredentialAPIProvider {
                await request.progress?(.authorizing)
                // Resolve once for this send only. A plan repair must not trigger another
                // Keychain dialog; credentials never persist in the workspace or history.
                responder = try await credentialProvider.resolve()
            } else { responder = underlying }
            var attempt = prepared
            // Only format/validation failures are repaired. Network, authorization and
            // cancellation errors retain their real cause and are never disguised as plans.
            for index in 0..<2 {
                try Task.checkCancellation()
                let result = try await responder.stream(to: attempt) { _ in
                    // Raw JSON is never displayed or executed before full validation.
                    if !announcement.sent { announcement.sent = true; delta("正在生成受控文件方案，尚未执行任何操作…") }
                }
                try Task.checkCancellation()
                RitoRequestTrace.event("plan_response_characters",count:result.text.count,flush:true)
                do {
                    let (message, call) = try RitoToolCall.decode(result.text, attachments: request.attachments)
                    RitoRequestTrace.event("plan_decoded",flush:true)
                    guard let call else { return .init(text: message, task: nil) }
                    let names = call.attachmentIDs.compactMap { id in request.attachments.first { $0.id == id }?.name }
                    let task = RToolAITaskPlan(id: UUID(), intent: call.operation.intent, sourceNames: names, liveCall: call)
                    return .init(text: message + "\n请先生成执行预览，再确认本机处理。", task: task)
                } catch {
                    guard error is RitoToolError || error is ToolExecutionError else { throw error }
                    RitoRequestTrace.event("plan_validation_rejected",count:1,flush:true)
                    if index == 1 { break }
                    await request.progress?(.repairingPlan)
                    // Standalone requests can start fresh. A follow-up needs its original task.
                    // Do not echo raw rejected output, local paths, filenames or error values.
                    attempt = RToolAIRequest(messages: prepared.continuesAttachmentTask ? prepared.messages : [], text: request.text, attachments: [], intent: request.intent,
                        toolInstructions: instruction + "\n上次输出未通过本机校验。请重新核对JSON结构、注册工具ID、附件ID、参数名、枚举、数值范围和步骤类型。不要猜测缺失参数；需要澄清请用task:null并在message中提问。只返回一个完整JSON对象。",
                        progress: request.progress, expectsToolPlan: true, continuesAttachmentTask: prepared.continuesAttachmentTask)
                }
            }
            try Task.checkCancellation()
            RitoRequestTrace.event("plan_recovery_exhausted",flush:true)
            // An explicitly labelled application notice is not passed off as a model answer
            // or a successfully processed file. The original attachments remain retryable.
            return .init(text: "应用提示：已连接 AI 服务并收到内容，但工具方案未通过格式或参数校验；自动修正一次后仍未通过。本次未执行任何文件操作。请从“全部工具”选择具体功能，补充所需参数后再试，或返回工具模式直接处理。", task: nil, applicationNotice: true)
        }
    }
}

@MainActor private final class RitoPlanAnnouncement { var sent = false }
