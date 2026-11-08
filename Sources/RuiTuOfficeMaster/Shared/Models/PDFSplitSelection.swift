import Foundation

/// Uses the same parser as actual PDF splitting; preview groups cannot diverge from output groups.
struct PDFSplitSelection {
    let ranges: [SplitRange]
    let error: String?
    var isValid: Bool { !ranges.isEmpty && error == nil }
    var totalPages: Int {
        ranges.reduce(0) { total, range in
            let sum = total.addingReportingOverflow(range.end - range.start + 1)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }
    init(text: String, pageCount: Int?) {
        guard let pageCount, pageCount > 0 else { ranges = []; error = nil; return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ranges = []; error = "请输入要拆分的页码，例如 1-3,5。"; return
        }
        guard text.count <= 256 else {
            ranges = []; error = "页码范围最多 256 个字符，请分批拆分。"; return
        }
        do { ranges = try PageRangeParser.parse(text,pageCount:pageCount); error = nil }
        catch {
            ranges = []
            self.error = "文档共 \(pageCount) 页，请输入 1–\(pageCount) 以内的页码；多个范围用逗号分隔。"
        }
    }
    static func editableText(_ proposed: String?) -> String {
        guard let proposed, proposed.count <= 256,
              (try? PageRangeParser.parse(proposed,pageCount:Int.max)) != nil else { return "" }
        return proposed
    }
}
