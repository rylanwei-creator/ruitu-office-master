#if os(macOS)
import SwiftUI

/// 设置页内部子页枚举
enum SettingsTab: String, CaseIterable {
    case appearance = "外观"
    case general = "通用"
    case storage = "存储"
    case feedback = "反馈"
    case about = "关于"
}

/// 设置主容器 — 水平标签页切换五个子页面
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .appearance

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeader(title: "设置", subtitle: "定制你的使用偏好")

            // 标签栏
            SettingsTabBar(selectedTab: $selectedTab)

            // 子页内容区
            switch selectedTab {
            case .appearance:
                AppearanceSettingsView()
            case .general:
                GeneralSettingsView()
            case .storage:
                StorageSettingsView()
            case .feedback:
                FeedbackSettingsView()
            case .about:
                AboutSettingsView()
            }

            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .frame(maxWidth: 900)
        .background(AppColors.background)
    }
}

// MARK: - 标签栏组件

private struct SettingsTabBar: View {
    @Binding var selectedTab: SettingsTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 14, weight: selectedTab == tab ? .semibold : .regular))
                        .foregroundColor(selectedTab == tab ? AppColors.primary : AppColors.textSecondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(
                            selectedTab == tab
                                ? AppColors.primaryLight
                                : Color.clear
                        )
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(AppColors.cardBackground)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.04), radius: 4, y: 1)
    }
}

#endif
