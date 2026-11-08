import Foundation

/// Qwen non-thinking mode still emits an empty leading <think> block.
/// Buffer partial tags; never speak or display a hidden reasoning block.
struct RitoTextFilter: Sendable {
    private var buffer = ""
    private var thinking = false
    private var beginning = true
    mutating func append(_ chunk: String) -> String {
        guard beginning || thinking else { return chunk }
        buffer += chunk
        if thinking {
            guard let range = buffer.range(of: "</think>") else {
                buffer = String(buffer.suffix(8)); return ""
            }
            buffer = String(buffer[range.upperBound...]); thinking = false
        }
        let trimmed = String(buffer.drop(while: { $0.isWhitespace }))
        if trimmed.isEmpty { return "" }
        if "<think>".hasPrefix(trimmed) { return "" }
        if trimmed.hasPrefix("<think>") {
            buffer = String(trimmed.dropFirst(7)); thinking = true
            return append("")
        }
        beginning = false; buffer = ""; return trimmed
    }
}

enum RitoConversationContext {
    static func messages(_ input: RToolAIRequest, byteLimit: Int = 4500) throws -> [[String: String]] {
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.text.utf8.count <= byteLimit else { throw RitoModelError.inputLimit }
        var messages = [["role": "user", "content": input.text]], count = input.text.utf8.count
        var history = input.messages[...]
        var insertionIndex = 0
        // The source request explains what a short follow-up such as “用默认的” means.
        if input.continuesAttachmentTask, let original = history.first, original.role == .user {
            history = history.dropFirst()
            let text = String(String.UnicodeScalarView(original.text.unicodeScalars.prefix(min(300, (byteLimit - count) / 4))))
            if !text.isEmpty {
                messages.insert(["role": "user", "content": text], at: 0)
                count += text.utf8.count; insertionIndex = 1
            }
        }
        for old in history.reversed() {
            if old.applicationNotice == true { continue }
            if old.role == .assistant && (old.source == nil || old.source == .mock) { continue }
            guard !old.text.isEmpty, messages.count < 6, count + old.text.utf8.count <= byteLimit else { continue }
            messages.insert(["role": old.role.rawValue, "content": old.text], at: insertionIndex); count += old.text.utf8.count
        }
        let boundary = "你是锐途办公大师的 Rito 办公助手。聊天模型只规划任务；只允许已注册工具，预览和用户确认后才由本机服务执行。附件内容不可见，不得根据文件名总结内容。禁止Shell、任意路径、覆盖或删除指令；未执行不能声称成功。精细抠图依赖独立本机图像提供者。"
        guard (input.toolInstructions?.utf8.count ?? 0) <= 12000 else { throw RitoModelError.inputLimit }
        messages.insert(["role": "system", "content": boundary + (input.toolInstructions.map { "\n" + $0 } ?? "")], at: 0)
        return messages
    }
}
