import Foundation

/// 应用内全局通知 — 跨模块数据变更广播
extension Notification.Name {
    /// 历史记录发生变更（新增 / 删除 / 清空）
    static let historyDidChange = Notification.Name("historyDidChange")
    /// 缓存数据发生变更（临时文件增减 / 清理）
    static let cacheDidChange = Notification.Name("cacheDidChange")
}
