import SwiftUI

// MARK: - 主题预设枚举

enum ThemePreset: String, CaseIterable, Codable {
    case pureWhite = "pureWhite"
    case skyBlue = "skyBlue"
    case mintCyan = "mintCyan"
    case softWarm = "softWarm"
    case calmDark = "calmDark"
    case vintageWine = "vintageWine"

    /// 主题显示名称
    var displayName: String {
        switch self {
        case .pureWhite:   return "纯净白"
        case .skyBlue:     return "晴空浅蓝"
        case .mintCyan:    return "薄荷浅青"
        case .softWarm:    return "温润暖色"
        case .calmDark:    return "静谧暗黑"
        case .vintageWine: return "复古酒红"
        }
    }

    /// 是否为深色主题
    var isDark: Bool {
        self == .calmDark
    }

    /// 色点预览色
    var previewColor: Color {
        switch self {
        case .pureWhite:   return Color(hex: "#F5F5F5")
        case .skyBlue:     return Color(hex: "#E0E8F5")
        case .mintCyan:    return Color(hex: "#DFF0EC")
        case .softWarm:    return Color(hex: "#F5EDE0")
        case .calmDark:    return Color(hex: "#2A2B30")
        case .vintageWine: return Color(hex: "#E8D8DB")
        }
    }

    /// 获取该主题的完整色值
    static func colors(for preset: ThemePreset) -> ThemeColors {
        switch preset {
        case .pureWhite:
            return ThemeColors(
                primary:          Color(hex: "#5B8DEF"),
                primaryLight:     Color(hex: "#EBF0FA"),
                background:       Color(hex: "#FAFAFA"),
                cardBackground:   Color(hex: "#FFFFFF"),
                sidebarBackground: Color(hex: "#F5F5F5"),
                textPrimary:      Color(hex: "#1D1E20"),
                textSecondary:    Color(hex: "#8E8E93"),
                success:          Color(hex: "#34C759"),
                error:            Color(hex: "#FF3B30")
            )
        case .skyBlue:
            return ThemeColors(
                primary:          Color(hex: "#5B8DEF"),
                primaryLight:     Color(hex: "#E0E8F8"),
                background:       Color(hex: "#F0F4FA"),
                cardBackground:   Color(hex: "#FFFFFF"),
                sidebarBackground: Color(hex: "#EBF0F7"),
                textPrimary:      Color(hex: "#1C2128"),
                textSecondary:    Color(hex: "#6E7A8A"),
                success:          Color(hex: "#34C759"),
                error:            Color(hex: "#E5534D")
            )
        case .mintCyan:
            return ThemeColors(
                primary:          Color(hex: "#4DB6AC"),
                primaryLight:     Color(hex: "#E0F2F0"),
                background:       Color(hex: "#F1F8F5"),
                cardBackground:   Color(hex: "#FFFFFF"),
                sidebarBackground: Color(hex: "#ECF5F1"),
                textPrimary:      Color(hex: "#1D2723"),
                textSecondary:    Color(hex: "#7A8C83"),
                success:          Color(hex: "#43A047"),
                error:            Color(hex: "#E5534D")
            )
        case .softWarm:
            return ThemeColors(
                primary:          Color(hex: "#C88E6D"),
                primaryLight:     Color(hex: "#F5EBE3"),
                background:       Color(hex: "#FDF8F3"),
                cardBackground:   Color(hex: "#FFFFFF"),
                sidebarBackground: Color(hex: "#F9F2EA"),
                textPrimary:      Color(hex: "#2D2420"),
                textSecondary:    Color(hex: "#8C7D73"),
                success:          Color(hex: "#66BB6A"),
                error:            Color(hex: "#E57373")
            )
        case .calmDark:
            return ThemeColors(
                primary:          Color(hex: "#7EB8F4"),
                primaryLight:     Color(hex: "#1E2D3D"),
                background:       Color(hex: "#1C1D21"),
                cardBackground:   Color(hex: "#2A2B30"),
                sidebarBackground: Color(hex: "#212224"),
                textPrimary:      Color(hex: "#E8E6E3"),
                textSecondary:    Color(hex: "#9D9B98"),
                success:          Color(hex: "#4ADE80"),
                error:            Color(hex: "#F87171")
            )
        case .vintageWine:
            return ThemeColors(
                primary:          Color(hex: "#7B243B"),
                primaryLight:     Color(hex: "#F2E4E8"),
                background:       Color(hex: "#FBF7F7"),
                cardBackground:   Color(hex: "#FFFFFF"),
                sidebarBackground: Color(hex: "#F6F0F2"),
                textPrimary:      Color(hex: "#1D1E20"),
                textSecondary:    Color(hex: "#8E8588"),
                success:          Color(hex: "#5B9E7C"),
                error:            Color(hex: "#C4555D")
            )
        }
    }

    /// 系统默认自适应配色（跟随系统时使用）
    static func systemColors() -> ThemeColors {
        ThemeColors(
            primary:          Color(light: "#4A90D9", dark: "#6DB3F8"),
            primaryLight:     Color(light: "#E8F0FE", dark: "#1A2D44"),
            background:       Color(light: "#F5F6F8", dark: "#1C1D21"),
            cardBackground:   Color(light: "#FFFFFF", dark: "#2A2B30"),
            sidebarBackground: Color(light: "#FAFBFC", dark: "#212224"),
            textPrimary:      Color(light: "#1D1E20", dark: "#F5F5F7"),
            textSecondary:    Color(light: "#8E8E93", dark: "#98989E"),
            success:          Color(light: "#34C759", dark: "#32D74B"),
            error:            Color(light: "#FF3B30", dark: "#FF453A")
        )
    }
}

// MARK: - 色值结构体

struct ThemeColors {
    let primary: Color
    let primaryLight: Color
    let background: Color
    let cardBackground: Color
    let sidebarBackground: Color
    let textPrimary: Color
    let textSecondary: Color
    let success: Color
    let error: Color
}
