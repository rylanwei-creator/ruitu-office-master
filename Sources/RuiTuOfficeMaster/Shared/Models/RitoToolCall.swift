import Foundation
import CoreFoundation
struct RitoToolCall: Codable, Sendable, Equatable {
    enum Operation: String, Codable, Sendable, CaseIterable {
        case ocr, pdf_merge, organize_copy, file_rename, organize_move, image_convert, image_compress, image_resize
        case cutout, watermark_remove, id_photo, id_photo_print, pdf_split, pdf_encrypt, pdf_watermark, pdf_image_watermark
        case word_to_pdf, pdf_to_word, video_compress, video_to_gif, gif_compress, speech_to_text, pdf_ocr, collage
        var intent: RToolAIIntent {
            switch self {
            case .ocr, .pdf_ocr: .extractText
            case .pdf_merge, .pdf_split, .pdf_encrypt, .pdf_watermark, .pdf_image_watermark, .word_to_pdf, .pdf_to_word: .pdfDocument
            case .organize_copy, .organize_move: .organize
            default: .plan
            }
        }
        var steps: [String] { ["核对输入与“" + ToolRegistry.lookup(self).name + "”参数", "选择输出位置并检查预览", "确认后由本机工具执行"] }
    }
    let operation: Operation
    var attachmentIDs: [UUID]
    var parameters: [String: String]? = nil
    var regionConfirmed: Bool? = nil
    var following: [RitoToolStage]? = nil
    static func decode(_ text: String, attachments: [RToolAIAttachment]) throws -> (String, RitoToolCall?) {
        do { return try decodeBody(text,attachments:attachments) }
        catch let error as RitoToolError { throw error }
        catch let error as ToolExecutionError { throw error }
        catch { throw RitoToolError.invalidPlan }
    }
    private static func jsonObject(_ text: String) throws -> [String:Any] {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("[") else { throw RitoToolError.invalidPlan }
        if let data = text.data(using:.utf8), let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any] { return object }
        // Accept one complete JSON object inside Markdown/prose. Braces inside quoted strings
        // are ignored; multiple objects and truncated strings are rejected, never guessed.
        var objects: [String] = [], current = "", depth = 0, quoted = false, escaped = false
        for character in text {
            if depth == 0 {
                if character == "{" { current = "{"; depth = 1; quoted = false; escaped = false }
                continue
            }
            current.append(character)
            if escaped { escaped = false; continue }
            if quoted && character == "\\" { escaped = true; continue }
            if character == "\"" { quoted.toggle(); continue }
            if !quoted {
                if character == "{" { depth += 1 }
                if character == "}" { depth -= 1; if depth == 0 { objects.append(current);current = "" } }
            }
        }
        guard depth == 0, objects.count == 1, let data = objects[0].data(using:.utf8),
              let object = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw RitoToolError.invalidPlan }
        return object
    }
    private static func decodeBody(_ text: String, attachments: [RToolAIAttachment]) throws -> (String, RitoToolCall?) {
        var content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fence = String(repeating: String(UnicodeScalar(96)!), count: 3)
        if content.hasPrefix(fence + "json"), content.hasSuffix(fence) { content = String(content.dropFirst(6).dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard content.utf8.count <= 24000 else { throw RitoToolError.invalidPlan }
        let object = try jsonObject(content)
        guard
              Set(object.keys).isSubset(of: ["message", "task"]), let message = object["message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RitoToolError.invalidPlan }
        guard let raw = object["task"], !(raw is NSNull) else { return (message, nil) }
        guard let task = raw as? [String: Any], Set(task.keys).isSubset(of: ["operation", "attachmentIDs", "parameters", "following"]),
              task["operation"] != nil, task["attachmentIDs"] != nil else { throw RitoToolError.invalidPlan }
        var normalized = task
        if task["parameters"] is NSNull { normalized.removeValue(forKey:"parameters") }
        else if let params = task["parameters"] {
            guard let values = params as? [String: Any] else { throw RitoToolError.invalidPlan }
            normalized["parameters"] = try scalarParameters(values)
        }
        if task["following"] is NSNull { normalized.removeValue(forKey:"following") }
        else if let following = task["following"] {
            guard let stages = following as? [[String: Any]], stages.count <= 3 else { throw RitoToolError.invalidPlan }
            normalized["following"] = try stages.map { stage -> [String: Any] in
                guard Set(stage.keys).isSubset(of: ["operation", "parameters"]), stage["operation"] != nil else { throw RitoToolError.invalidPlan }
                var result = stage
                if let params = stage["parameters"] {
                    guard let values = params as? [String: Any] else { throw RitoToolError.invalidPlan }
                    result["parameters"] = try scalarParameters(values)
                }
                return result
            }
        }
        let call = try JSONDecoder().decode(Self.self, from: JSONSerialization.data(withJSONObject: normalized))
        try ToolRegistry.validate(call, attachments: attachments, allowMissing: true)
        try TaskEngine.validateChain(call)
        return (message, call)
    }
    private static func scalarParameters(_ values: [String: Any]) throws -> [String: String] {
        try values.mapValues { value in
            if let text = value as? String { return text }
            if let number = value as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
                return number.stringValue
            }
            throw RitoToolError.invalidPlan
        }
    }
}
struct RitoToolStage: Codable, Sendable, Equatable {
    let operation: RitoToolCall.Operation
    var parameters: [String: String]? = nil
}
enum RitoToolError: LocalizedError {
    case invalidPlan, missingFiles, changed, destinationOccupied
    var errorDescription: String? {
        switch self {
        case .invalidPlan: "AI 未生成有效的受控方案，未执行文件操作。请从已注册工具中选择功能并补充有效参数。"
        case .missingFiles: "这份方案的原文件授权已失效，请重新添加文件或文件夹并生成方案。"
        case .changed: "文件或目标位置在预览后已变化，请重新生成预览。"
        case .destinationOccupied: "预览中的目标位置已被占用，未覆盖已有文件，请重新预览。"
        }
    }
}
