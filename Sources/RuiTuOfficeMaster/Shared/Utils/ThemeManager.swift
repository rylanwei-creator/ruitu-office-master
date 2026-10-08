import SwiftUI

// MARK: - 主题管理器（单例）

@Observable
final class ThemeManager {
    nonisolated(unsafe) static let shared = ThemeManager()

    // MARK: 存储属性（@Observable 自动追踪）

    /// 是否跟随系统外观
    var followSystem: Bool = true {
        didSet {
            UserDefaults.standard.set(followSystem, forKey: "theme_followSystem")
        }
    }

    /// 选中的预设主题 rawValue
    var selectedPresetRaw: String? = nil {
        didSet {
            UserDefaults.standard.set(selectedPresetRaw, forKey: "theme_selectedPreset")
        }
    }

    // MARK: 计算属性

    /// 当前选中的主题预设
    var selectedPreset: ThemePreset? {
        get {
            guard let raw = selectedPresetRaw else { return nil }
            return ThemePreset(rawValue: raw)
        }
        set {
            selectedPresetRaw = newValue?.rawValue
            followSystem = false
        }
    }

    /// 当前生效的色值
    var currentColors: ThemeColors {
        if followSystem {
            return ThemePreset.systemColors()
        }
        return ThemePreset.colors(for: selectedPreset ?? .pureWhite)
    }

    /// 全局颜色方案
    var colorScheme: ColorScheme? {
        guard !followSystem else { return nil }
        return selectedPreset?.isDark == true ? .dark : .light
    }

    // MARK: 操作方法

    func selectPreset(_ preset: ThemePreset) {
        withAnimation(.easeInOut(duration: 0.3)) {
            self.selectedPreset = preset
        }
    }

    func setFollowSystem(_ value: Bool) {
        withAnimation(.easeInOut(duration: 0.3)) {
            self.followSystem = value
        }
    }

    // MARK: 初始化

    private init() {
        let defaults = UserDefaults.standard
        // 恢复"跟随系统"：键不存在时默认为 true（属性已声明默认值 true）
        if defaults.object(forKey: "theme_followSystem") != nil {
            self.followSystem = defaults.bool(forKey: "theme_followSystem")
        }
        self.selectedPresetRaw = defaults.string(forKey: "theme_selectedPreset")
    }
}
