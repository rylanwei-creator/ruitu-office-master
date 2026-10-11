#if os(macOS)
import SwiftUI

/// 关于 — 版本信息、检查更新、版权声明
struct AboutSettingsView: View {
    private let model = AppUpdateViewModel.shared
    private var appVersion: String { model.currentVersion }
    private var buildNumber: String { model.buildNumber }
    private let developer = "锐途工作室"
    private let copyright = "Copyright © 2026 锐途工作室. All rights reserved."
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // App 信息
                SettingsSection(title: "应用信息") {
                    VStack(spacing: 16) {
                        // Logo + 名称
                        HStack(spacing: 16) {
                            if let logoPath = AppResources.bundle.path(forResource: "Logo", ofType: "png"),
                               let nsImage = NSImage(contentsOfFile: logoPath) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 64, height: 64)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("锐途办公大师")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundColor(AppColors.textPrimary)
                                Text("一站式文件批量处理工具")
                                    .font(.system(size: 14))
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }

                        Divider().opacity(0.5)

                        // 版本信息
                        InfoRow(label: "版本号", value: appVersion)
                        InfoRow(label: "Build", value: buildNumber)
                        InfoRow(label: "最低系统", value: "macOS 14.0")
                        InfoRow(label: "技术栈", value: "SwiftUI + SwiftData")
                    }
                }

                SettingsSection(title: "更新与官网") {
                    SoftwareUpdateView()
                }

                // 开发者
                SettingsSection(title: "开发者") {
                    InfoRow(label: "开发团队", value: developer)
                    InfoRow(label: "技术支持", value: "如需帮助或提交问题，请前往反馈页面留言")
                }

                // 版权
                SettingsSection(title: "版权声明") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(copyright)
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textPrimary)
                        Text("文件处理在本机完成。语音识别只使用本地能力；系统翻译可能需要下载语言资源。发送反馈时，你填写的内容会提交至反馈服务。")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - 信息行组件

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppColors.textPrimary)
            Spacer()
        }
    }
}

#endif
