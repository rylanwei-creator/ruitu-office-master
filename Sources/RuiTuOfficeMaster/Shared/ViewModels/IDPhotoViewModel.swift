import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class IDPhotoViewModel {
    var settings = IDPhotoSettings()
    private(set) var sourceURL: URL?
    private(set) var asset: IDPhotoAsset?
    private(set) var result: IDPhotoResult?
    private(set) var isLoading = false
    private(set) var isRendering = false
    private(set) var isExporting = false
    var errorMessage: String?
    var saveMessage: String?
    var paper: IDPhotoPaper = .sixInch { didSet { if oldValue != paper { refreshPrintPreview() } } }
    var cropMarks = true { didSet { if oldValue != cropMarks { refreshPrintPreview() } } }
    private(set) var printPreview: IDPhotoPrintPreview?
    private(set) var isPrintPreviewRendering = false
    private(set) var printPreviewError: String?
    private var printGeneration = UUID()
    private var printTask: Task<Void, Never>?
    var showGuides = true
    private var preparedEditor: CGImage?
    private var quarterTurns = 0
    private var generation = UUID()
    private var task: Task<Void, Never>?
    var busy: Bool { isLoading || isRendering || isExporting || isPrintPreviewRendering }
    var canExport: Bool { result?.settings == settings && result != nil && !isLoading && !isRendering && !isExporting }
    var currentPrintPreview: IDPhotoPrintPreview? {
        guard result?.settings == settings, let printPreview, printPreview.settings == settings,
              printPreview.paper == paper, printPreview.cropMarks == cropMarks else { return nil }
        return printPreview
    }
    var canExportPrint: Bool { canExport && currentPrintPreview != nil && !isPrintPreviewRendering }
    var editorImage: CGImage? { preparedEditor ?? asset?.image }
    var faceMessage: String {
        guard let asset else { return "" }
        if asset.faceDetectionFailed { return "人脸检测未完成，可手动裁切；自动换底暂不可用。" }
        if asset.faces.isEmpty { return "未检测到人脸，可手动裁切；自动换底需清晰的单人正面照片。" }
        if asset.faces.count > 1 { return "检测到 \(asset.faces.count) 张人脸，请换用单人照片后换底。" }
        return "已检测到 1 张人脸。自动构图仅作起点，请检查头顶、下巴和肩部留白。"
    }
    var resolutionWarning: Bool {
        guard let asset, (try? settings.validate()) != nil else { return false }
        let rect = settings.crop.rect(in: asset.size, aspect: settings.millimeters.width / settings.millimeters.height)
        return rect.width < settings.pixelSize.width || rect.height < settings.pixelSize.height
    }
    private func activity() { ProcessingActivity.setActive(busy, owner: ObjectIdentifier(self)) }
    func selectPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff, .bmp]
        panel.allowsMultipleSelection = false
        panel.message = "请选择清晰的单人正面照片，建议头部与肩部完整入镜。"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }
    func load(_ url: URL, rotate: Bool = false) {
        guard !isExporting else { return }
        task?.cancel(); generation = UUID()
        invalidatePrintPreview()
        let token = generation
        if !rotate { quarterTurns = 0; settings.crop = IDPhotoCrop() }
        sourceURL = url; asset = nil; result = nil; preparedEditor = nil
        errorMessage = nil; saveMessage = nil
        isLoading = true; isRendering = false; activity()
        let turns = quarterTurns
        task = Task {
            let worker = Task.detached(priority: .userInitiated) {
                try await IDPhotoWorker.shared.prepare(url: url, quarterTurns: turns)
            }
            do {
                let prepared = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard token == generation, !Task.isCancelled else { return }
                asset = prepared
                isLoading = false
                autoFrame(refresh: false)
                refresh()
            } catch {
                guard token == generation else { return }
                isLoading = false; activity()
                if !(error is CancellationError) { errorMessage = "无法读取照片：\(error.localizedDescription)" }
            }
        }
    }
    func rotateClockwise() {
        guard let sourceURL, !isLoading, !isExporting else { return }
        quarterTurns = (quarterTurns + 1) % 4
        load(sourceURL, rotate: true)
    }
    func clear() {
        guard !isExporting else { return }
        task?.cancel(); generation = UUID()
        invalidatePrintPreview()
        sourceURL = nil; asset = nil; result = nil; preparedEditor = nil
        isLoading = false; isRendering = false; activity()
        errorMessage = nil; saveMessage = nil
        settings.crop = IDPhotoCrop()
    }
    func cancel() {
        task?.cancel(); generation = UUID()
        invalidatePrintPreview()
        isLoading = false; isRendering = false; activity()
        errorMessage = nil
        if result == nil { saveMessage = "已停止；调整设置或点击“更新预览”继续。" }
    }
    func autoFrame(refresh shouldRefresh: Bool = true) {
        guard let asset, asset.faces.count == 1, (try? settings.validate()) != nil else { return }
        settings.crop = .framing(face: asset.faces[0], image: asset.size,
                                 aspect: settings.millimeters.width / settings.millimeters.height)
        if shouldRefresh { refresh() }
    }
    func refresh() {
        guard let asset, !isLoading, !isExporting else { return }
        task?.cancel(); generation = UUID()
        invalidatePrintPreview()
        let token = generation, snapshot = settings
        result = nil; errorMessage = nil; saveMessage = nil
        do { try snapshot.validate() }
        catch { isRendering = false; activity(); errorMessage = error.localizedDescription; return }
        isRendering = true; activity()
        task = Task {
            do {
                try await Task.sleep(for: .milliseconds(220))
                let worker = Task.detached(priority: .userInitiated) {
                    try await IDPhotoWorker.shared.render(asset: asset, settings: snapshot)
                }
                let output = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard token == generation, !Task.isCancelled, snapshot == settings else { return }
                result = output
                preparedEditor = output.editorImage
                isRendering = false
                refreshPrintPreview()
                activity()
            } catch {
                guard token == generation else { return }
                isRendering = false; activity()
                if !(error is CancellationError) { errorMessage = error.localizedDescription }
            }
        }
    }
    private func invalidatePrintPreview() {
        printTask?.cancel(); printGeneration = UUID()
        printPreview = nil; printPreviewError = nil; isPrintPreviewRendering = false
    }
    func refreshPrintPreview() {
        guard !isExporting else { return }
        invalidatePrintPreview()
        guard let result, result.settings == settings, !isLoading, !isRendering else { activity(); return }
        let token = printGeneration, paper = paper, marks = cropMarks
        isPrintPreviewRendering = true; activity()
        printTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let worker = Task.detached(priority: .userInitiated) {
                    try IDPhotoService.printPreview(result: result, paper: paper, cropMarks: marks)
                }
                let output = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard token == printGeneration, !Task.isCancelled, result.settings == settings,
                      paper == self.paper, marks == cropMarks else { return }
                printPreview = output; isPrintPreviewRendering = false; activity()
            } catch {
                guard token == printGeneration else { return }
                isPrintPreviewRendering = false; activity()
                if !(error is CancellationError) { printPreviewError = error.localizedDescription }
            }
        }
    }
    func export(printSheet: Bool) {
        guard canExport, let result, let sourceURL else { return }
        guard !printSheet || canExportPrint else { return }
        // 捕获预览所用的 PDF；保存不重新排版，避免参数变化与预览不一致。
        let exportData = printSheet ? currentPrintPreview?.data : result.data
        guard let exportData else { return }
        isExporting = true; activity(); errorMessage = nil; saveMessage = nil
        Task {
            defer { isExporting = false; activity() }
            do {
                let path = try await Task.detached(priority: .userInitiated) {
                    let directory = try CacheManager.makeTaskDirectory(in: CacheManager.imageCacheDirectory)
                    do {
                        let ext = printSheet ? "pdf" : result.settings.format == .jpeg ? "jpg" : "png"
                        let suffix = printSheet ? "证件照排版" : "证件照"
                        let base = String(sourceURL.deletingPathExtension().lastPathComponent.prefix(80))
                        let url = directory.appendingPathComponent("\(base)_\(suffix).\(ext)")
                        try exportData.write(to: url, options: .atomic)
                        return url
                    } catch { try? FileManager.default.removeItem(at: directory); throw error }
                }.value
                defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
                guard let report = await ResultExporter.save([path]) else { return }
                saveMessage = report.message
                if !report.errors.isEmpty { errorMessage = report.errors.joined(separator: "\n") }
                if !report.savedURLs.isEmpty {
                    HistoryService().addRecord(toolName: "证件照", operationType: printSheet ? "打印排版" : "单张导出", fileCount: 1,
                        inputFileNames: [sourceURL.lastPathComponent], status: "成功", inputSize: FileUtils.fileSize(of: sourceURL),
                        outputSize: FileUtils.fileSize(of: path), descriptionText: "\(Int(result.settings.pixelSize.width))×\(Int(result.settings.pixelSize.height)) px，\(result.settings.dpi) DPI，\(result.settings.background.rawValue)")
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
