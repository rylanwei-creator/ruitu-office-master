import SwiftUI

struct SoftwareUpdateView: View {
    @State private var model = AppUpdateViewModel.shared
    private var statusColor: Color {
        if model.errorMessage != nil { return AppColors.error }
        if model.result?.relation == .current { return AppColors.success }
        return AppColors.primary
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { versionLabel; Spacer(); checkButton }
                VStack(alignment: .leading, spacing: 12) { versionLabel; checkButton }
            }
            HStack(alignment: .top, spacing: 10) {
                if model.isChecking { ProgressView().controlSize(.small).padding(.top, 2) }
                else {
                    Image(systemName: model.errorMessage != nil ? "exclamationmark.circle.fill" : model.result?.relation == .current ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .foregroundStyle(statusColor).padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.statusTitle).font(.headline).foregroundStyle(statusColor)
                    Text(model.statusDetail).font(.callout).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
                    if let date = model.checkedAt { Text("检查时间：\(date.formatted(date: .abbreviated, time: .standard))").font(.caption).foregroundStyle(AppColors.textSecondary) }
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(statusColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 12) {
                Button { model.openWebsite() } label: { Label("访问官网", systemImage: "globe") }
                Button { model.openReleases() } label: {
                    Label(model.result?.relation == .updateAvailable ? "查看更新并下载" : "查看发布页", systemImage: "arrow.up.right.square")
                }
            }.buttonStyle(.bordered)
            if let error = model.linkError { Text(error).font(.callout).foregroundStyle(AppColors.error) }
            Text("仅在点击时联网检查，不上传文件；更新安装需自行下载并替换应用。")
                .font(.caption).foregroundStyle(AppColors.textSecondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var versionLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("软件更新").font(.headline)
            Text("当前版本 \(model.currentVersion)（Build \(model.buildNumber)）").font(.callout).foregroundStyle(AppColors.textSecondary)
        }
    }
    private var checkButton: some View {
        Button { Task { await model.check() } } label: {
            Label(model.isChecking ? "正在检查…" : "检查更新", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline).padding(.horizontal, 8).padding(.vertical, 5)
        }.buttonStyle(.borderedProminent).tint(AppColors.primary).disabled(model.isChecking)
    }
}

struct SoftwareUpdateSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("版本检查").font(.title2.bold()); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            SoftwareUpdateView()
        }.padding(24).frame(width: 500)
    }
}
