import SwiftUI
import AppKit

/// 全局颜色常量 — 委托 ThemeManager 实现主题换肤
enum AppColors {
    /// 当前生效的色值
    private static var colors: ThemeColors {
        ThemeManager.shared.currentColors
    }

    static var primary: Color          { colors.primary }
    static var primaryLight: Color     { colors.primaryLight }
    static var background: Color       { colors.background }
    static var cardBackground: Color   { colors.cardBackground }
    static var sidebarBackground: Color { colors.sidebarBackground }
    static var textPrimary: Color      { colors.textPrimary }
    static var textSecondary: Color    { colors.textSecondary }
    static var success: Color          { colors.success }
    static var error: Color            { colors.error }
}

// MARK: - 从十六进制字符串创建 Color（macOS）

extension Color {
    /// 支持深浅双色的便捷初始化
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(lightHex: light, darkHex: dark))
    }

    /// 单色十六进制初始化
    init(hex: String) {
        self.init(nsColor: NSColor(hex: hex))
    }
}

// MARK: - NSColor 从十六进制创建（macOS）

extension NSColor {
    convenience init(lightHex: String, darkHex: String) {
        self.init(
            name: nil,
            dynamicProvider: { appearance in
                let hex = appearance.name == .darkAqua
                    || appearance.name == .vibrantDark
                    || appearance.name == .accessibilityHighContrastDarkAqua
                    || appearance.name == .accessibilityHighContrastVibrantDark
                    ? darkHex : lightHex
                return NSColor(hex: hex)
            }
        )
    }

    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: .alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let r, g, b: CGFloat
        switch hex.count {
        case 6:
            r = CGFloat((int >> 16) & 0xFF) / 255
            g = CGFloat((int >> 8) & 0xFF) / 255
            b = CGFloat(int & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}
