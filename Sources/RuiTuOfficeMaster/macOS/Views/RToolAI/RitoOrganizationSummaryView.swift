#if os(macOS)
import SwiftUI

struct RitoOrganizationSummaryView: View {
    let summary: RitoOrganizationSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.categories.isEmpty ? "没有成功归类的文件" : "已整理为 \(summary.categories.count) 大类")
                .font(.system(size: 13, weight: .semibold))
            Text("成功 \(summary.successCount) · 跳过 \(summary.skippedCount) · 失败 \(summary.failureCount)")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(summary.categories) { category in
                HStack(spacing: 9) {
                    Image(systemName: "folder.fill").foregroundStyle(RToolAIStyle.accent)
                    Text(category.name).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(category.count) 个文件").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }.padding(10)
                    .background(RToolAIStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
            }
            if summary.otherCount > 0 || summary.uncategorizedSuccessCount > 0 {
                Text("另有 \(summary.otherCount + summary.uncategorizedSuccessCount) 条记录缺少分类信息或处于其他状态，请在文件整理记录中查看。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text("这里只展示分类汇总；具体文件请打开结果文件夹查看。")
                .font(.caption2).foregroundStyle(.secondary)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
}
#endif
