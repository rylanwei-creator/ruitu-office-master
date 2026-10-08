#if os(macOS)
import SwiftUI

struct StorageSettingsView: View {
    @State private var cacheSize: Int64 = 0
    @State private var recordCount = 0
    @State private var isCalculating = false
    @State private var isClearing = false
    @State private var showClearAlert = false
    @State private var message: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: "临时文件") {
                    HStack {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(isCalculating ? "计算中…" : FileUtils.formatSize(cacheSize))
                                .font(.system(size: 28, weight: .bold))
                            Text("包含尚未保存的处理结果。清理不会删除已保存文件和历史记录。")
                                .font(.system(size: 12)).foregroundColor(AppColors.textSecondary)
                        }
                        Spacer()
                        Button("清理临时文件") { showClearAlert = true }
                            .buttonStyle(.bordered)
                            .disabled(isCalculating || isClearing || cacheSize == 0)
                    }
                    if let message { Text(message).font(.system(size: 12)).foregroundColor(AppColors.textSecondary) }
                }
                SettingsSection(title: "历史记录") {
                    Text("共有 \(recordCount) 条记录。可在侧边栏的历史记录页面单独删除。")
                        .font(.system(size: 13))
                }
                SettingsSection(title: "自动清理") {
                    Text("启动时清理超过 7 天的旧会话缓存。当前会话的处理结果不会因停留时间过长而自动删除。")
                        .font(.system(size: 13)).foregroundColor(AppColors.textSecondary)
                }
            }
        }
        .onAppear { calculateCacheSize() }
        .onReceive(NotificationCenter.default.publisher(for: .cacheDidChange)) { _ in calculateCacheSize() }
        .alert("清理临时文件？", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) { clearCache() }
        } message: { Text("尚未保存的处理结果将被删除。请先保存需要的文件；正在处理或保存时不能清理。") }
    }
    private func calculateCacheSize() {
        guard !isCalculating else { return }
        isCalculating = true
        recordCount = HistoryService().fetchAll().count
        Task {
            cacheSize = await Task.detached { CacheManager.totalCacheSize }.value
            isCalculating = false
        }
    }
    private func clearCache() {
        guard !ProcessingActivity.isBusy else { message = CacheError.processing.localizedDescription; return }
        isClearing = true
        // 在主线程完成互斥检查与删除，期间不能开始新的界面任务。
        do { try CacheManager.clearAll(); message = "临时文件已清理，历史记录保留" }
        catch { message = error.localizedDescription }
        isClearing = false
        calculateCacheSize()
    }
}
#endif
