#if os(macOS)
import SwiftUI

/// 外观设置 — 主题换肤
struct AppearanceSettingsView: View {
    /// 当前选中的预设（当跟随系统关闭时生效）
    private var activePreset: ThemePreset? {
        ThemeManager.shared.followSystem ? nil : ThemeManager.shared.selectedPreset
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 跟随系统
                SettingsCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("跟随系统外观", isOn: Binding(
                            get: { ThemeManager.shared.followSystem },
                            set: { ThemeManager.shared.setFollowSystem($0) }
                        ))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)

                        Text("开启后自动根据 macOS 系统外观切换明暗主题")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary)

                        Divider().opacity(0.5)

                        // 自定义主题色点
                        VStack(alignment: .leading, spacing: 12) {
                            Text("自定义主题色")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColors.textPrimary)

                            HStack(spacing: 10) {
                                ForEach(ThemePreset.allCases, id: \.self) { preset in
                                    ThemeDotView(
                                        preset: preset,
                                        isSelected: activePreset == preset,
                                        disabled: ThemeManager.shared.followSystem
                                    ) {
                                        ThemeManager.shared.selectPreset(preset)
                                    }
                                }
                            }
                        }
                        .opacity(ThemeManager.shared.followSystem ? 0.35 : 1.0)
                    }
                }
            }
        }
    }
}

// MARK: - 设置卡片容器

/// 统一的设置卡片，带圆角和阴影
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(20)
        .frame(maxWidth: 600, alignment: .leading)
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}

// MARK: - 预设色点组件

private struct ThemeDotView: View {
    let preset: ThemePreset
    let isSelected: Bool
    let disabled: Bool
    let action: () -> Void

    @State private var isHovered = false
    private let dotSize: CGFloat = 28

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(preset.previewColor)
                    .frame(width: dotSize, height: dotSize)

                Circle()
                    .stroke(
                        isSelected ? AppColors.primary : Color.gray.opacity(0.4),
                        lineWidth: isSelected ? 3 : 1.5
                    )
                    .frame(width: dotSize, height: dotSize)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .scaleEffect(isHovered && !disabled ? 1.15 : 1.0)
            .animation(.easeInOut(duration: 0.2), value: isHovered)
            .onHover { hovering in
                isHovered = hovering && !disabled
            }
            .onTapGesture {
                guard !disabled else { return }
                action()
            }

            Text(preset.displayName)
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary.opacity(0.55))
                .opacity(isHovered && !disabled ? 1.0 : 0.0)
        }
        .frame(width: 64)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

#endif
