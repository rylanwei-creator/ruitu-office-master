import Foundation

/// 反馈月度提交上限追踪 — UserDefaults 持久化，每月自动重置
struct FeedbackLimitTracker {
    static let maxPerMonth = 1000
    static let warningThreshold = 950

    private static let countKey = "FeedbackLimitTracker.successCount"
    private static let monthKey = "FeedbackLimitTracker.currentMonth"

    /// 当前统计月份（如 "2026-05"）
    private static var currentMonthKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    /// 当月已成功提交次数（跨月自动归零），与 increment() 共用同一锁保证原子性
    static var successCount: Int {
        lock.lock()
        defer { lock.unlock() }
        let storedMonth = UserDefaults.standard.string(forKey: monthKey) ?? ""
        if storedMonth != currentMonthKey {
            UserDefaults.standard.set(0, forKey: countKey)
            UserDefaults.standard.set(currentMonthKey, forKey: monthKey)
            return 0
        }
        return UserDefaults.standard.integer(forKey: countKey)
    }

    /// 是否还可以提交
    static var canSubmit: Bool { successCount < maxPerMonth }

    /// 是否接近上限（≥950）
    static var isNearLimit: Bool {
        let count = successCount
        return count >= warningThreshold && count < maxPerMonth
    }

    /// 剩余可提交次数
    static var remaining: Int { max(0, maxPerMonth - successCount) }

    /// 发送成功后调用，计数 +1 并持久化
    private static let lock = NSLock()
    static func increment() {
        lock.lock()
        defer { lock.unlock() }
        let storedMonth = UserDefaults.standard.string(forKey: monthKey) ?? ""
        let current = (storedMonth == currentMonthKey)
            ? UserDefaults.standard.integer(forKey: countKey)
            : 0
        UserDefaults.standard.set(current + 1, forKey: countKey)
        UserDefaults.standard.set(currentMonthKey, forKey: monthKey)
    }
}
