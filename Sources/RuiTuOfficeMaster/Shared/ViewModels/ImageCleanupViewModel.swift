import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor @Observable
final class ImageCleanupViewModel {
    let tool: ImageCleanupTool
    private(set) var sourceURL: URL?
    private(set) var asset: CleanupImageAsset?
    private(set) var workingImage: CGImage?
    private(set) var undoImage: CGImage?
    private(set) var hasResult = false
    private(set) var isLoading = false
    private(set) var isProcessing = false
    private(set) var isSaving = false
    var region: CleanupRegion?
    var sampleCenter: CGPoint?
    var repairMethod: WatermarkRepairMethod = .surrounding
    var feather = 0.0
    var pickingSample = false
    var errorMessage: String?
    var statusMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    var busy: Bool { isLoading || isProcessing || isSaving }
    var canProcess: Bool { workingImage != nil && !busy && (tool == .cutout || region != nil) }
    var canSave: Bool { hasResult && workingImage != nil && !busy }
    init(tool: ImageCleanupTool) { self.tool = tool }
    private func activity() { ProcessingActivity.setActive(busy, owner: ObjectIdentifier(self)) }

    func chooseImage() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        Task { if await FileDialogs.response(to: panel) == .OK, let url = panel.url { load(url) } }
    }
    func load(_ url: URL) {
        guard !isSaving else { return }
        task?.cancel(); generation = UUID(); let token = generation
        sourceURL = url; asset = nil; workingImage = nil; undoImage = nil; hasResult = false
        region = nil; sampleCenter = nil; pickingSample = false; errorMessage = nil; statusMessage = nil
        isLoading = true; isProcessing = false; activity()
        task = Task {
            let worker = Task.detached(priority: .userInitiated) { try ImageCleanupService.prepare(url) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard token == generation, !Task.isCancelled else { return }
                asset = result; workingImage = result.image; isLoading = false; activity()
            } catch {
                guard token == generation else { return }
                isLoading = false; activity()
                if !(error is CancellationError) { errorMessage = "读取图片失败：\(error.localizedDescription)" }
            }
        }
    }
    func clear() {
        guard !isSaving else { return }
        cancel(); sourceURL = nil; asset = nil; workingImage = nil; undoImage = nil; hasResult = false
        region = nil; sampleCenter = nil; statusMessage = nil; errorMessage = nil
    }
    func cancel() {
        guard !isSaving else { return }
        task?.cancel(); generation = UUID(); isLoading = false; isProcessing = false; activity()
        statusMessage = "已停止，已完成的图片保留。"; errorMessage = nil
    }
    func restoreOriginal() {
        guard !busy, let asset else { return }
        workingImage = asset.image; undoImage = nil; hasResult = false; region = nil; sampleCenter = nil
        errorMessage = nil; statusMessage = "已恢复原图。"
    }
    func undo() {
        guard !busy, let undoImage else { return }
        workingImage = undoImage; self.undoImage = nil; hasResult = true
        errorMessage = nil; statusMessage = "已撤销上一步处理。"
    }
    func process(erase: Bool = false) {
        guard canProcess, let workingImage else { return }
        if erase && region == nil { errorMessage = "请先框选需要清除的背景区域。"; return }
        let original = workingImage
        let source = tool == .cutout && !erase ? (asset?.image ?? original) : original
        let region = region, center = sampleCenter, method = repairMethod, feather = feather, tool = tool
        generation = UUID(); let token = generation
        isProcessing = true; activity(); errorMessage = nil; statusMessage = nil
        task = Task {
            let worker = Task.detached(priority: .userInitiated) { () throws -> (CGImage, String) in
                if erase, let region { return (try ImageCleanupService.erase(source, region: region), "已清除框选区域，可撤销。") }
                if tool == .cutout {
                    let cutout = try ImageCleanupService.cutout(source)
                    return (cutout.image, "抠图完成，保留 \(cutout.subjects) 个前景主体；请检查边缘后保存透明 PNG。")
                }
                guard let region else { throw CleanupError.message("请先框选水印。") }
                if method == .sample {
                    guard let center else { throw CleanupError.message("请点击“设置取样位置”，选择干净背景。") }
                    return (try ImageCleanupService.sample(source, region: region, center: center, feather: feather), "取样修补完成，请对比原图检查接缝。")
                }
                return (try ImageCleanupService.surrounding(source, region: region), "周边修补完成；复杂纹理可改用取样修补。")
            }
            do {
                let (image, message) = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard token == generation, !Task.isCancelled else { return }
                undoImage = original; self.workingImage = image; hasResult = true
                statusMessage = message; isProcessing = false; activity()
            } catch {
                guard token == generation else { return }
                isProcessing = false; activity()
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }
    func save() {
        guard canSave, let image = workingImage, let sourceURL else { return }
        isSaving = true; activity(); errorMessage = nil; statusMessage = nil
        let suffix = tool == .cutout ? "抠图" : "去水印"
        Task {
            defer { isSaving = false; activity() }
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    let directory = try CacheManager.makeTaskDirectory(in: CacheManager.imageCacheDirectory)
                    do {
                        let file = directory.appendingPathComponent(String(sourceURL.deletingPathExtension().lastPathComponent.prefix(80)) + "_\(suffix).png")
                        try ImageCodec.encode(image, type: .png, quality: 1).write(to: file, options: .atomic)
                        return file
                    } catch { try? FileManager.default.removeItem(at: directory); throw error }
                }.value
                defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                guard let report = await ResultExporter.save([url]) else { return }
                statusMessage = report.message
                errorMessage = report.errors.isEmpty ? nil : report.errors.joined(separator: "\n")
                if !report.savedURLs.isEmpty {
                    HistoryService().addRecord(toolName: suffix, operationType: "PNG 导出", fileCount: 1,
                        inputFileNames: [sourceURL.lastPathComponent], status: "成功", inputSize: FileUtils.fileSize(of: sourceURL),
                        outputSize: FileUtils.fileSize(of: url), descriptionText: "\(image.width)×\(image.height) px；原文件未改动")
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
