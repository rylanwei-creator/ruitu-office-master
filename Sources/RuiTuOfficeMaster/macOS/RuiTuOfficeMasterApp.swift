#if os(macOS)
import SwiftUI
import AppKit

// MARK: - AppDelegate：彻底修复键盘输入焦点问题
///
/// 根因：SPM executableTarget 编译产物不是 .app bundle，macOS 默认将
/// NSApp.activationPolicy 设为 .prohibited。App 可以显示窗口、TextField
/// 可以成为窗口内 firstResponder（显示光标），但系统层面 App 永远无法接收
/// 键盘事件——所有按键被路由到其他已激活的应用。
///
/// 修复分两层：
/// 1. 强制设置 activationPolicy = .regular，让 App 成为合法前台应用
/// 2. NavigationSplitView + hiddenTitleBar 补偿：激活时确保窗口是 key window

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 最早的生命周期钩子——在 SwiftUI 装配 WindowGroup 之前执行
    func applicationWillFinishLaunching(_ notification: Notification) {
        // 核心修复：SPM 无 bundle 可执行文件默认 activationPolicy 是 .prohibited
        // 必须显式设为 .regular，否则 App 永远无法接收键盘事件
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 等 SwiftUI WindowGroup 创建好窗口后再激活
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            NSApp.activate(ignoringOtherApps: true)
            ensureKeyWindow()
        }
    }

    /// 关闭窗口时最小化至程序坞（而非退出应用）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppSettings.shared.minimizeToTray
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ProcessingActivity.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "仍有任务正在处理或保存"
        alert.informativeText = "现在退出会中断任务，尚未保存的结果可能需要重新处理。建议先停止任务并保存结果。"
        alert.addButton(withTitle: "继续处理")
        alert.addButton(withTitle: "仍然退出")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    /// App 从后台切回前台时，补偿 NavigationSplitView + hiddenTitleBar 的 key window 丢失
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            ensureKeyWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }

    private func ensureKeyWindow() {
        for window in NSApp.windows where window.isVisible && !window.isKeyWindow {
            window.makeKey()
        }
    }
}

// MARK: - App 入口

@main
struct RuiTuOfficeMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
                .transaction { transaction in
                    if !AppSettings.shared.enableAnimations { transaction.disablesAnimations = true }
                }
                .preferredColorScheme(ThemeManager.shared.colorScheme)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        NSApp.windows.first(where: { $0.isVisible })?.makeKey()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
    }
}

#endif
