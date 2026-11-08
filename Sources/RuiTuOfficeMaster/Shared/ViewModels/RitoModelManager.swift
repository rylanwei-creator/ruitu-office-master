import Foundation
import Observation
import AppKit

@MainActor @Observable final class RitoModelManager {
    enum Phase: Equatable { case uninstalled, checking, downloading, ready, failed, cancelled }
    static let shared = RitoModelManager()
    private(set) var phase: Phase = .uninstalled
    private(set) var progress = 0.0
    private(set) var detail = "未安装本地模型，普通工具不受影响"
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    let store: RitoModelStore
    init(store: RitoModelStore = .standard) { self.store = store }
    var busy: Bool { phase == .checking || phase == .downloading }
    func check() {
        guard !busy else { return }
        begin(.checking) { [store] _ in try store.verify(RitoModelManifest.bundled()) }
    }
    func download() {
        guard !busy else { return }
        begin(.downloading) { [store] progress in
            try await RitoModelDownloader.download(store: store, manifest: RitoModelManifest.bundled(), progress: progress)
        }
    }
    func importDirectory() async {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "选择已下载的 Qwen3 1.7B MLX 4-bit 官方模型目录，导入前校验固定版本的全部文件。"
        guard await FileDialogs.response(to: panel) == .OK, let url = panel.url else { return }
        begin(.checking) { [store] _ in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            try store.importFiles(from: url, manifest: RitoModelManifest.bundled())
        }
    }
    func cancel() {
        operationID = UUID(); work?.cancel(); work = nil; phase = .cancelled
        detail = "已取消。完整且校验通过的文件保留；未完成的文件下次重新下载。"
    }
    func unload() { Task { await RitoLocalEngine.shared.unload() }; detail = "已请求卸载模型，生成停止后释放内存。" }
    private func begin(_ phase: Phase, action: @escaping @Sendable (@escaping @MainActor @Sendable (Double) -> Void) async throws -> Void) {
        let id = UUID(); operationID = id; self.phase = phase; progress = 0
        detail = phase == .downloading ? "下载约 0.93 GB，随后进行完整校验…" : "正在检查模型文件…"
        work = Task {
            do {
                let child = Task.detached {
                    try await action { [weak self] value in
                        guard let self, self.operationID == id else { return }
                        self.progress = min(1, max(0, value))
                    }
                }
                try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
                try Task.checkCancellation()
                guard operationID == id else { return }
                self.phase = .ready; progress = 1; detail = "Qwen3 1.7B 4-bit 已安装并通过校验，可离线聊天。"; work = nil
            } catch {
                guard operationID == id else { return }
                if let modelError = error as? RitoModelError, case .missing = modelError { self.phase = .uninstalled }
                else { self.phase = error is CancellationError ? .cancelled : .failed }
                detail = error.localizedDescription; work = nil
            }
        }
    }
}
