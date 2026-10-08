import SwiftUI
import UniformTypeIdentifiers

/// URL Transferable 一次交付整批文件，避免异步 provider 回调打乱顺序及反复预估。
struct FileDropZone: View {
    let hasFiles: Bool
    let isImporting: Bool
    let select: () -> Void
    let clear: () -> Void
    let cancelImport: () -> Void
    let receive: ([URL]) -> Void
    @State private var targeted = false
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle").font(.system(size: 32)).foregroundStyle(AppColors.textSecondary)
            Text(isImporting ? "正在扫描和校验图片…" : "拖入图片或文件夹，也可以点击选择")
                .font(.system(size: 13)).foregroundStyle(AppColors.textSecondary)
            Text("文件夹会递归导入静态图片，跳过隐藏项、应用包及目录链接")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
            HStack(spacing: 12) {
                if isImporting {
                    ProgressView().controlSize(.small)
                    Button("停止导入", action: cancelImport)
                } else {
                    Button(action: select) { Label("选择图片或文件夹", systemImage: "folder") }
                    if hasFiles { Button(action: clear) { Label("清空列表", systemImage: "trash") } }
                }
            }.buttonStyle(.bordered)
        }
        .padding(24).frame(maxWidth: .infinity)
        .background(AppColors.cardBackground.opacity(0.6))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? AppColors.primary : AppColors.textSecondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .dropDestination(for: URL.self) { urls, _ in
            guard !isImporting, !urls.isEmpty else { return false }
            receive(urls); return true
        } isTargeted: { targeted = $0 }
    }
}
