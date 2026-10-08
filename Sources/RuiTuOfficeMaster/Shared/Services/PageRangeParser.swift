import Foundation

enum PageRangeParser {
    static func parse(_ text: String, pageCount: Int) throws -> [SplitRange] {
        let normalized = text.replacingOccurrences(of: "，", with: ",").replacingOccurrences(of: "–", with: "-")
        let parts = normalized.components(separatedBy: ",")
        var ranges: [SplitRange] = []
        for part in parts {
            let values = part.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "-")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(values.count), let first = Int(values[0]),
                  let last = values.count == 1 ? first : Int(values[1]),
                  first >= 1, last >= first, last <= pageCount else {
                throw PDFError.invalidPageRange(part)
            }
            ranges.append(SplitRange(start: first, end: last))
        }
        return ranges
    }
}
