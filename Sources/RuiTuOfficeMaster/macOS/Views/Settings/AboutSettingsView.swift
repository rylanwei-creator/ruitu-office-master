#if os(macOS)
import SwiftUI

/// 关于 — 版本信息、检查更新、版权声明
struct AboutSettingsView: View {
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
    private let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "2"
    private let developer = "锐途工作室"
    private let copyright = "Copyright © 2026 锐途工作室. All rights reserved."
    private let updateURL = "https://github.com/wjr22917/RuiTuOfficeMaster/releases"

    @State private var isCheckingUpdate = false
    @State private var updateToast: UpdateToast?

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

                // 检查更新
                SettingsSection(title: "更新") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("软件更新")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(AppColors.textPrimary)
                            Text("当前版本 \(appVersion) (Build \(buildNumber))")
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary)
                        }

                        Spacer()

                        Button {
                            checkForUpdate()
                        } label: {
                            HStack(spacing: 6) {
                                if isCheckingUpdate {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                Text("查看发布页")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.primary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(AppColors.primary.opacity(0.5), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isCheckingUpdate)
                    }

                    Text("点击检查更新将打开浏览器查看最新版本发布页")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary.opacity(0.7))
                        .padding(.top, 4)
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
        .overlay(alignment: .top) {
            if let toast = updateToast {
                ResultToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: updateToast)
    }

    // MARK: - 检查更新

    private func checkForUpdate() {
        isCheckingUpdate = true
        updateToast = nil

        // 尝试访问更新页，检测网络可达性
        guard let url = URL(string: updateURL) else {
            isCheckingUpdate = false
            showUpdateToast(.failure, "更新地址配置错误")
            return
        }

        NSWorkspace.shared.open(url)
        isCheckingUpdate = false
        showUpdateToast(.success, "已打开版本发布页")
    }

    private func showUpdateToast(_ type: UpdateToastType, _ text: String) {
        updateToast = UpdateToast(type: type, message: text)
        Task {
            try? await Task.sleep(for: .seconds(3))
            updateToast = nil
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

// MARK: - 更新提示

private enum UpdateToastType {
    case success, failure, info
}

private struct UpdateToast: Equatable {
    let type: UpdateToastType
    let message: String

    static func == (lhs: UpdateToast, rhs: UpdateToast) -> Bool {
        lhs.type == rhs.type && lhs.message == rhs.message
    }
}

private struct ResultToastView: View {
    let toast: UpdateToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(toast.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppColors.textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(AppColors.cardBackground)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }

    private var icon: String {
        switch toast.type {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch toast.type {
        case .success: return AppColors.success
        case .failure: return AppColors.error
        case .info: return AppColors.primary
        }
    }
}

#endif
