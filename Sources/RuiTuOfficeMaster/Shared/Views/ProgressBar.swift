import SwiftUI

/// 通用进度条组件 — 带百分比和当前处理文件名
struct ProgressBar: View {
    @Binding var progress: Double  // 0.0 ~ 1.0
    var currentFile: String = ""

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 进度条本体
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // 背景轨道
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(light: "#E5E5EA", dark: "#3A3A3C"))
                        .frame(height: 6)

                    // 已完成进度
                    RoundedRectangle(cornerRadius: 3)
                        .fill(AppColors.primary)
                        .frame(width: geometry.size.width * clampedProgress, height: 6)
                }
            }
            .frame(height: 6)

            // 进度信息
            HStack {
                if !currentFile.isEmpty {
                    Text("处理中: \(currentFile)")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(Int(clampedProgress * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.primary)
            }
        }
        .frame(maxWidth: 400)
    }
}
