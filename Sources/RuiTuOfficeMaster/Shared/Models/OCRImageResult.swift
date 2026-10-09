import Foundation

/// 每条结果保留来源与稳定标识；文件名相同也不会合并。
struct OCRImageResult: Identifiable, Sendable {
    enum Status: Equatable, Sendable {
        case recognized
        case noText
        case failed(String)
    }

    let id: UUID
    let sourceURL: URL
    var text: String
    var translatedText: String = ""
    let status: Status

    init(id: UUID = UUID(), sourceURL: URL, text: String, status: Status = .recognized) {
        self.id = id
        self.sourceURL = sourceURL
        self.text = text
        self.status = status
    }

    var fileName: String { sourceURL.lastPathComponent }
    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var notice: String? {
        switch status {
        case .recognized: return nil
        case .noText: return "未识别到文字，可检查图片清晰度或调整识别设置。"
        case .failed(let message): return "识别失败：\(message)"
        }
    }

    static func combinedText(_ results: [Self], translated: Bool = false) -> String {
        results.enumerated().map { index, result in
            let content = translated ? result.translatedText : result.text
            let fallback = translated ? "暂无译文" : (result.notice ?? "无文字")
            return "--- 图片 \(index + 1)：\(result.fileName) ---\n\(content.isEmpty ? fallback : content)"
        }.joined(separator: "\n\n")
    }
}
