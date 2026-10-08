import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

/// 应用全局设置持久化管理器
@Observable
final class AppSettings {
    nonisolated(unsafe) static let shared = AppSettings()

    // MARK: - 通用设置

    /// 开机自启
    var launchAtLogin: Bool = false {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "settings_launchAtLogin")
            #if os(macOS)
            guard !isApplyingLaunchAtLogin else { return }
            applyLaunchAtLogin()
            #endif
        }
    }

    /// 关闭窗口时最小化至托盘（隐藏而非退出）
    var minimizeToTray: Bool = false {
        didSet {
            UserDefaults.standard.set(minimizeToTray, forKey: "settings_minimizeToTray")
        }
    }

    /// 界面动画开关
    var enableAnimations: Bool = true {
        didSet {
            UserDefaults.standard.set(enableAnimations, forKey: "settings_enableAnimations")
        }
    }

    // MARK: - 初始化

    private init() {
        let defaults = UserDefaults.standard

        // launchAtLogin: 恢复或设为默认 false
        self.launchAtLogin = defaults.bool(forKey: "settings_launchAtLogin")

        // minimizeToTray: 首次运行时键不存在，默认 false
        if defaults.object(forKey: "settings_minimizeToTray") != nil {
            self.minimizeToTray = defaults.bool(forKey: "settings_minimizeToTray")
        }

        // enableAnimations: 首次运行时键不存在，默认 true
        if defaults.object(forKey: "settings_enableAnimations") != nil {
            self.enableAnimations = defaults.bool(forKey: "settings_enableAnimations")
        }
    }

    // MARK: - 操作

    /// 一键恢复全部默认设置
    func resetAll() {
        launchAtLogin = false
        minimizeToTray = false
        enableAnimations = true
    }

    /// 防止 didSet 递归：applyLaunchAtLogin 内部回退属性时不再触发自身
    private var isApplyingLaunchAtLogin = false

    #if os(macOS)
    /// 应用开机自启设置（SMAppService）
    private func applyLaunchAtLogin() {
        isApplyingLaunchAtLogin = true
        defer { isApplyingLaunchAtLogin = false }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // 注册失败：回退 UserDefaults + 属性（guard 防止递归）
            UserDefaults.standard.set(!launchAtLogin, forKey: "settings_launchAtLogin")
            launchAtLogin = !launchAtLogin
        }
    }
    #endif
}
