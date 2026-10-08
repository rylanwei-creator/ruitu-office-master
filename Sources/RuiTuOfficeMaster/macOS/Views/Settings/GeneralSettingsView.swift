#if os(macOS)
import SwiftUI

/// 通用设置 — 开机自启、最小化托盘、动画开关、恢复默认
struct GeneralSettingsView: View {
    @State private var showResetAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // 启动与窗口
                SettingsSection(title: "启动与窗口") {
                    SettingsToggleRow(
                        icon: "power",
                        title: "开机自启",
                        description: "登录系统时自动启动锐途办公大师",
                        isOn: Binding(
                            get: { AppSettings.shared.launchAtLogin },
                            set: { AppSettings.shared.launchAtLogin = $0 }
                        )
                    )

                    Divider().opacity(0.5)

                    SettingsToggleRow(
                        icon: "dock.arrow.down.rectangle",
                        title: "关闭窗口时最小化至程序坞",
                        description: "点击关闭按钮后隐藏窗口而非退出应用",
                        isOn: Binding(
                            get: { AppSettings.shared.minimizeToTray },
                            set: { AppSettings.shared.minimizeToTray = $0 }
                        )
                    )
                }

                // 界面
                SettingsSection(title: "界面") {
                    SettingsToggleRow(
                        icon: "sparkles",
                        title: "界面动画",
                        description: "关闭可减少动效，提升低配设备流畅度",
                        isOn: Binding(
                            get: { AppSettings.shared.enableAnimations },
                            set: { AppSettings.shared.enableAnimations = $0 }
                        )
                    )
                }

                // 恢复默认
                SettingsSection(title: "高级") {
                    Button {
                        showResetAlert = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 14))
                            Text("恢复全部默认设置")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundColor(AppColors.error)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(AppColors.error.opacity(0.4), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Text("将外观、通用、存储等所有设置恢复为初始状态")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                }
            }
        }
        .alert("确认恢复默认", isPresented: $showResetAlert) {
            Button("取消", role: .cancel) {}
            Button("确认恢复", role: .destructive) {
                AppSettings.shared.resetAll()
            }
        } message: {
            Text("所有设置将恢复为初始状态，此操作不可撤销。")
        }
    }
}

#endif
