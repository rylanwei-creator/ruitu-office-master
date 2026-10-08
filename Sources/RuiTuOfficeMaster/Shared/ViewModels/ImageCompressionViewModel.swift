import Foundation
import SwiftUI
import UniformTypeIdentifiers

// PNG 使用无损编码；这些档位只调整 JPG、HEIC 等有损输出的质量。
enum CompressionLevel: String, CaseIterable, Sendable {
    case light = "轻度压缩", balanced = "均衡压缩", strong = "强力压缩", custom = "自定义"
    var description: String {
        switch self { case .light: return "画质优先"; case .balanced: return "推荐"; case .strong: return "体积优先"; case .custom: return "手动调整" }
    }
    var qualityValue: Double {
        switch self { case .light: return 0.92; case .balanced: return 0.72; case .strong: return 0.42; case .custom: return 0.75 }
    }
    var expectedReduction: String { "不保证固定缩减比例" }
}

enum SizeMode: String, CaseIterable, Sendable {
    case aspectRatio = "等比适应宽高", custom = "自定义宽高", maxDimension = "限定最大边长"
}

enum OutputFormat: String, CaseIterable, Sendable {
    case keepOriginal = "保留原格式", jpg = "JPG", png = "PNG", webp = "WebP", heic = "HEIC"
    static var available: [Self] {
        allCases.filter {
            switch $0 {
            case .keepOriginal: return true
            case .jpg: return ImageCodec.supports(.jpeg)
            case .png: return ImageCodec.supports(.png)
            case .webp: return ImageCodec.supports(.webP)
            case .heic: return ImageCodec.supports(.heic)
            }
        }
    }
}

@MainActor @Observable
final class ImageCompressionViewModel {
    var selectedImages: [URL] = []
    var compressionLevel: CompressionLevel = .balanced
    var quality: Double = 0.72 { didSet { if oldValue != quality { invalidateResults() } } }
    var showCustomSlider = false
    var sizeMode: SizeMode = .aspectRatio { didSet { if oldValue != sizeMode { invalidateResults(); refreshEstimates() } } }
    var maxDimension: CGFloat = 2048 { didSet { if oldValue != maxDimension { invalidateResults() } } }
    var customWidth = "" { didSet { if oldValue != customWidth { invalidateResults() } } }
    var customHeight = "" { didSet { if oldValue != customHeight { invalidateResults() } } }
    var aspectWidth = "" { didSet { if oldValue != aspectWidth { invalidateResults() } } }
    var aspectHeight = "" { didSet { if oldValue != aspectHeight { invalidateResults() } } }
    var outputFormat: OutputFormat = .keepOriginal { didSet { if oldValue != outputFormat { invalidateResults() } } }
    var originalSizes: [URL: Int64] = [:]
    var estimatedSizes: [URL: Int64] = [:]
    var isEstimating = false
    var estimationFailed = false
    var isImporting = false
    var isSaving = false
    var isProcessing = false { didSet { ProcessingActivity.setActive(isProcessing, owner: ObjectIdentifier(self)) } }
    var progress: Double = 0
    var currentFileName = ""
    var results: [CompressionResult] = []
    var successMessage: String?
    var errorMessage: String?
    private var estimationTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private(set) var taskID: UUID?
    private let taskManager: FileTaskManager
    private var importedDimensions: [URL: CGSize] = [:]
    private var importedTypes: [URL: String] = [:]
    init(taskManager: FileTaskManager = .shared) { self.taskManager = taskManager }
    deinit { ProcessingActivity.setActive(false, owner: ObjectIdentifier(self)) }
    var messageColor: Color {
        if errorMessage != nil { return results.isEmpty ? AppColors.error : .orange }
        if let taskID, taskManager.record(taskID)?.state == .cancelled { return .orange }
        return AppColors.success
    }
    var messageIcon: String { messageColor == AppColors.success ? "checkmark.circle.fill" : "info.circle.fill" }
    var canRetry: Bool { taskID.map { taskManager.canRetry($0) } ?? false }
    private var estimateID = UUID()

    var effectiveQuality: Double { compressionLevel == .custom ? quality : compressionLevel.qualityValue }
    var effectiveMaxDimension: CGFloat? { sizeMode == .maxDimension ? maxDimension : nil }
    private var customSize: CGSize? {
        sizeMode == .custom ? CGSize(width: Int(customWidth) ?? 0, height: Int(customHeight) ?? 0) : nil
    }
    private var boundingSize: CGSize? {
        sizeMode == .aspectRatio ? CGSize(width: Int(aspectWidth) ?? 0, height: Int(aspectHeight) ?? 0) : nil
    }
    var aspectRatio: CGFloat {
        guard let url = selectedImages.first, let size = importedDimensions[url] else { return 1 }
        return size.width / size.height
    }
    var imageCountText: String { "已选择 \(selectedImages.count) 张图片" }
    var originalTotalSizeText: String { FileUtils.formatSize(originalSizes.values.reduce(0, +)) }
    var hasCompleteEstimate: Bool {
        !selectedImages.isEmpty && selectedImages.allSatisfy { (estimatedSizes[$0] ?? 0) > 0 }
    }
    private var estimatedTotalSize: Int64 { selectedImages.reduce(0) { $0 + (estimatedSizes[$1] ?? 0) } }
    private var originalTotalSize: Int64 { selectedImages.reduce(0) { $0 + (originalSizes[$1] ?? 0) } }
    private var estimateStatusText: String {
        if isEstimating { return "计算中…" }
        return estimationFailed ? "无法预估" : "待估算"
    }
    var estimatedSizeText: String {
        hasCompleteEstimate ? FileUtils.formatSize(estimatedTotalSize) : estimateStatusText
    }
    var estimatedSavedPercent: Int {
        guard hasCompleteEstimate, originalTotalSize > 0 else { return 0 }
        return Int((1 - Double(estimatedTotalSize) / Double(originalTotalSize)) * 100)
    }
    var estimatedChangeText: String {
        guard hasCompleteEstimate, originalTotalSize > 0 else { return estimateStatusText }
        if estimatedTotalSize == originalTotalSize { return "体积不变" }
        let increased = estimatedTotalSize > originalTotalSize
        let direction = increased ? "增加" : "减少"
        let percent = abs(estimatedSavedPercent)
        return percent == 0 ? "约\(direction)不到 1%" : "约\(direction) \(percent)%"
    }
    var estimatedChangeColor: Color {
        guard hasCompleteEstimate, originalTotalSize > 0 else { return AppColors.textSecondary }
        if estimatedTotalSize > originalTotalSize { return .orange }
        return estimatedTotalSize < originalTotalSize ? AppColors.success : AppColors.textSecondary
    }
    var qualityPercent: Int { Int(effectiveQuality * 100) }
    var validationMessage: String? {
        guard effectiveQuality.isFinite, (0...1).contains(effectiveQuality) else { return CompressionError.invalidQuality.localizedDescription }
        let svc = ImageCompressionService()
        for url in selectedImages {
            do {
                guard let size = importedDimensions[url], let identifier = importedTypes[url], let type = UTType(identifier) else { return "图片信息不完整，请重新导入" }
                if outputFormat == .keepOriginal, !ImageCodec.supports(type) { return "本机不支持原格式编码，请选择 JPG 或 PNG" }
                if outputFormat != .keepOriginal { _ = try svc.outputType(for: outputFormat, originalURL: url) }
                _ = try ImageCodec.outputSize(original: size, maxDimension: effectiveMaxDimension,
                                              targetSize: customSize, fitWithin: boundingSize)
            } catch { return error.localizedDescription }
        }
        return nil
    }
    var canExecute: Bool { !selectedImages.isEmpty && !isProcessing && !isImporting && !isSaving && validationMessage == nil }
    var hasLargeFiles: Bool { originalSizes.values.contains { $0 > 50_000_000 } }
    var largeFileWarning: String? { hasLargeFiles ? "包含超过 50MB 的图片，处理可能需要较长时间" : nil }
    var smallFileNote: String? {
        outputFormat == .png ? "PNG 不减少颜色层次。仅重新编码可能不会变小；缩小尺寸或选择 JPG 可进一步减小体积。" : "转换格式或调整尺寸后，文件可能变大。结果会保留你选择的质量，不会擅自降级。"
    }

    func selectCompressionLevel(_ level: CompressionLevel) {
        invalidateResults()
        compressionLevel = level
        showCustomSlider = level == .custom
        if level != .custom { quality = level.qualityValue }
        refreshEstimates()
    }
    func syncHeightFromWidth() {
        if let w = Int(aspectWidth), (1...16384).contains(w) {
            let h = max(1, Int((CGFloat(w) / aspectRatio).rounded()))
            if abs((Int(aspectHeight) ?? 0) - h) > 1 { aspectHeight = String(h) }
        }
        refreshEstimates()
    }
    func syncWidthFromHeight() {
        if let h = Int(aspectHeight), (1...16384).contains(h) {
            let w = max(1, Int((CGFloat(h) * aspectRatio).rounded()))
            if abs((Int(aspectWidth) ?? 0) - w) > 1 { aspectWidth = String(w) }
        }
        refreshEstimates()
    }
    func selectImages() {
        guard !isProcessing, !isImporting, !isSaving else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = ImageCompressionService.supportedFormats
        Task { [weak self] in
            guard await FileDialogs.response(to: panel) == .OK else { return }
            self?.importImages(from: panel.urls)
        }
    }
    func removeImage(url: URL) {
        guard !isProcessing, !isImporting, !isSaving else { return }
        selectedImages.removeAll { $0 == url }
        originalSizes.removeValue(forKey: url)
        importedDimensions.removeValue(forKey: url); importedTypes.removeValue(forKey: url)
        invalidateResults()
        refreshEstimates()
    }
    func moveImages(from source: IndexSet, to destination: Int) {
        guard !isProcessing, !isImporting, !isSaving else { return }
        selectedImages.move(fromOffsets: source, toOffset: destination)
        invalidateResults()
    }
    func addImages(from urls: [URL]) {
        guard !isProcessing, !isImporting, !isSaving else { return }
        do { apply(try ImageFileImporter.collect(urls, excluding: selectedImages)) }
        catch { errorMessage = error.localizedDescription }
    }
    func importImages(from urls: [URL]) {
        guard !isProcessing, !isImporting, !isSaving else { return }
        estimationTask?.cancel(); isEstimating = false
        isImporting = true; errorMessage = nil
        let excluded = selectedImages
        importTask = Task { [weak self] in
            do {
                let report = try await ImageFileImporter.collectInBackground(urls, excluding: excluded)
                try Task.checkCancellation()
                self?.apply(report)
            } catch { self?.errorMessage = error is CancellationError ? "导入已停止，原列表保留" : error.localizedDescription }
            self?.isImporting = false
            self?.refreshEstimates()
        }
    }
    func cancelImport() { importTask?.cancel() }
    private func apply(_ report: ImageImportReport) {
        let wasEmpty = selectedImages.isEmpty
        invalidateResults()
        for image in report.images {
            selectedImages.append(image.url); originalSizes[image.url] = image.size
            importedDimensions[image.url] = image.dimensions; importedTypes[image.url] = image.typeIdentifier
        }
        if wasEmpty, let first = selectedImages.first, let size = importedDimensions[first] {
            aspectWidth = String(Int(size.width)); aspectHeight = String(Int(size.height))
        }
        errorMessage = report.message
        if report.duplicates > 0 { successMessage = "已跳过 \(report.duplicates) 个重复文件" }
        refreshEstimates()
    }
    func clearImages() {
        guard !isProcessing, !isImporting, !isSaving else { return }
        selectedImages = []; originalSizes = [:]; importedDimensions = [:]; importedTypes = [:]
        invalidateResults(); refreshEstimates()
    }
    private func invalidateResults() { taskID = nil; results = []; successMessage = nil; errorMessage = nil; progress = 0 }
    func refreshEstimates() {
        estimationTask?.cancel()
        estimatedSizes = [:]
        isEstimating = false; estimationFailed = false
        let id = UUID(); estimateID = id
        guard !selectedImages.isEmpty, !isProcessing, !isImporting else { return }
        guard validationMessage == nil else { estimationFailed = true; return }
        isEstimating = true
        let urls = selectedImages, q = effectiveQuality, fmt = outputFormat
        let maxDim = effectiveMaxDimension, target = customSize, box = boundingSize
        estimationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            let worker = Task.detached(priority: .utility) {
                var values: [URL: Int64] = [:]
                for url in urls {
                    if Task.isCancelled { break }
                    do {
                        values[url] = try await ImageCompressionWorker.shared.estimate(url: url, quality: q,
                            maxDimension: maxDim, outputFormat: fmt, targetSize: target, fitWithin: box)
                    } catch {
                        if Task.isCancelled { break }
                        values[url] = 0
                    }
                }
                return values
            }
            let values = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard !Task.isCancelled, self?.estimateID == id else { return }
            self?.estimatedSizes = values
            self?.isEstimating = false
            self?.estimationFailed = values.values.contains(0)
        }
    }
    func executeCompression() {
        guard canExecute else { errorMessage = validationMessage; return }
        estimationTask?.cancel()
        estimateID = UUID(); isEstimating = false
        results = []; successMessage = nil; errorMessage = nil
        let q = effectiveQuality, fmt = outputFormat
        let maxDim = effectiveMaxDimension, target = customSize, box = boundingSize
        let settings = "\(compressionLevel.rawValue) · 质量 \(Int(q * 100))% · \(fmt.rawValue) · \(sizeMode.rawValue)" +
            (maxDim.map { " \(String(format: "%.0f", Double($0)))px" } ?? "") + (target.map { " \(Int($0.width))×\(Int($0.height))px" } ?? "") + (box.map { " \(Int($0.width))×\(Int($0.height))px" } ?? "")
        let id = taskManager.enqueue(tool: "图片处理", configuration: settings, sources: selectedImages) { url in
            let type = try ImageCompressionService().outputType(for: fmt, originalURL: url)
            let dir = try CacheManager.makeTaskDirectory(in: CacheManager.imageCacheDirectory)
            let destination = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_处理." + (type.preferredFilenameExtension ?? "png"))
            do {
                try await ImageCompressionWorker.shared.compress(url: url, quality: q, maxDimension: maxDim,
                    outputFormat: fmt, outputURL: destination, targetSize: target, fitWithin: box)
                return FileTaskOutput(url: destination, inputSize: FileUtils.fileSize(of: url), outputSize: FileUtils.fileSize(of: destination))
            } catch { try? FileManager.default.removeItem(at: dir); throw error }
        } onChange: { [weak self] record in
            guard self?.taskID == record.id else { return }
            self?.consume(record)
        }
        taskID = id
        if let record = taskManager.record(id) { consume(record) }
    }
    private func consume(_ record: FileTaskRecord) {
        isProcessing = record.state.isActive; progress = record.progress
        currentFileName = record.cancellationRequested && record.state.isActive ? "正在停止，当前图片编码结束后退出…" : record.currentFile
        results = record.files.compactMap { item in
            guard item.state == .completed, let output = item.output else { return nil }
            return CompressionResult(originalURL: item.source, compressedURL: output.url, originalSize: output.inputSize, compressedSize: output.outputSize)
        }
        guard !record.state.isActive else { return }
        for result in results { originalSizes[result.originalURL] = result.originalSize; estimatedSizes[result.originalURL] = result.compressedSize }
        estimationFailed = !hasCompleteEstimate && record.failed > 0
        successMessage = record.summary
        errorMessage = record.files.compactMap { item in item.error.map { "\(item.source.lastPathComponent)：\($0)" } }.joined(separator: "\n")
        if errorMessage?.isEmpty == true { errorMessage = nil }
        HistoryService().addRecord(toolName: "图片处理", operationType: "压缩与尺寸调整", fileCount: record.files.count,
            inputFileNames: record.files.map { $0.source.lastPathComponent }, status: record.state.title,
            inputSize: results.reduce(0) { $0 + $1.originalSize }, outputSize: results.reduce(0) { $0 + $1.compressedSize }, descriptionText: record.summary)
    }
    func cancelProcessing() { if let taskID { taskManager.cancel(taskID) } }
    func retryFailed() { if let taskID { taskManager.retry(taskID) } }
    func saveResults() {
        guard !isProcessing, !isSaving, !results.isEmpty else { return }
        let urls = results.map(\.compressedURL)
        isSaving = true
        Task {
            defer { isSaving = false }
            if let report = await ResultExporter.save(urls) {
                if let taskID { taskManager.recordExport(taskID, report: report) }
                successMessage = report.message
                errorMessage = report.errors.isEmpty ? nil : report.errors.joined(separator: "\n")
            }
        }
    }
}
