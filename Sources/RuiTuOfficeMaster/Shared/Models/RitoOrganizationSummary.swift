import Foundation

/// Summarizes local execution metadata, never guesses a successful copy from a filename.
struct RitoOrganizationSummary: Equatable {
    struct Category: Identifiable, Equatable {
        let name: String
        let count: Int
        var id: String { name }
    }
    static let categoryOrder = ["图片", "文档", "视频", "音频", "压缩包", "代码", "其他"]
    let categories: [Category]
    let successCount: Int
    let skippedCount: Int
    let failureCount: Int
    let otherCount: Int
    let uncategorizedSuccessCount: Int

    init(results: [RToolAIResult]) {
        var counts: [String: Int] = [:]
        var success = 0, skipped = 0, failed = 0, other = 0
        for result in results {
            // Older history stored "成功：文档/filename" rather than separate metadata.
            let delimiter = result.detail.firstIndex { $0 == "：" || $0 == ":" }
            let legacyPhase = delimiter.flatMap { OrganizerPhase(rawValue: String(result.detail[..<$0])) }
            let legacyCategory = delimiter.map {
                String(result.detail[result.detail.index(after: $0)...].split(separator: "/", maxSplits: 1).first ?? "")
            }
            let phase = result.organizationPhase ?? legacyPhase
            let category = result.organizationCategory ?? legacyCategory
            switch phase {
            case .completed:
                success += 1
                if let category, Self.categoryOrder.contains(category) { counts[category, default: 0] += 1 }
            case .skipped: skipped += 1
            case .failed: failed += 1
            default: other += 1
            }
        }
        categories = Self.categoryOrder.compactMap { name in counts[name].map { Category(name: name, count: $0) } }
        successCount = success; skippedCount = skipped; failureCount = failed; otherCount = other
        uncategorizedSuccessCount = success - counts.values.reduce(0, +)
    }
}
