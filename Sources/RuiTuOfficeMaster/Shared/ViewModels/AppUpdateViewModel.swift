import Foundation
import AppKit
import Observation

@MainActor @Observable
final class AppUpdateViewModel {
    static let shared = AppUpdateViewModel()
    let currentVersion: String
    let buildNumber: String
    private(set) var isChecking = false
    private(set) var result: UpdateCheckResult?
    private(set) var checkedAt: Date?
    private(set) var errorMessage: String?
    private(set) var linkError: String?
    @ObservationIgnored private let service: AppUpdateService
    init(currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未标记",
         buildNumber: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未标记",
         service: AppUpdateService = .init()) {
        self.currentVersion = currentVersion; self.buildNumber = buildNumber; self.service = service
    }
    var statusTitle: String {
        if isChecking { return "正在检查最新版本…" }
        if errorMessage != nil { return "未能完成检查" }
        guard let result else { return "检查当前版本是否有更新" }
        switch result.relation {
        case .updateAvailable: return "发现新版本 \(result.latestVersion)"
        case .current: return "已是最新正式发布版"
        case .localNewer: return "当前版本较新"
        }
    }
    var statusDetail: String {
        if isChecking { return "正在连接 GitHub，请稍候。" }
        if let errorMessage { return errorMessage }
        guard let result else { return "点击检查后会与 GitHub 的最新正式发布版本比较。" }
        switch result.relation {
        case .updateAvailable: return "当前 \(currentVersion)，最新 \(result.latestVersion)。可查看更新说明并下载新版。"
        case .current: return "当前 \(currentVersion) 与 GitHub 正式版 \(result.latestVersion) 一致。"
        case .localNewer: return "当前 \(currentVersion)，GitHub 正式版为 \(result.latestVersion)。无需降级。"
        }
    }
    func check() async {
        guard !isChecking else { return }
        isChecking = true; result = nil; checkedAt = nil; errorMessage = nil; linkError = nil
        defer { isChecking = false }
        do {
            result = try await service.check(currentVersion: currentVersion)
            checkedAt = Date()
        } catch is CancellationError { errorMessage = "检查已取消，请重试。" }
        catch let error as URLError {
            errorMessage = error.code == .timedOut ? "连接 GitHub 超时，请检查网络后重试。" : "无法连接 GitHub，请检查网络后重试，或直接查看发布页。"
        } catch { errorMessage = error.localizedDescription }
    }
    func openWebsite() { open(AppLinks.website) }
    func openReleases() { open(AppLinks.releases) }
    private func open(_ url: URL) {
        linkError = NSWorkspace.shared.open(url) ? nil : "无法打开浏览器，请稍后重试。"
    }
}
