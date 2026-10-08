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
    var quality: Double = 0.72
    var showCustomSlider = false
    var sizeMode: SizeMode = .aspectRatio { didSet { refreshEstimates() } }
    var maxDimension: CGFloat = 2048
    var customWidth = ""
    var customHeight = ""
    var aspectWidth = ""
    var aspectHeight = ""
    var outputFormat: OutputFormat = .keepOriginal
    var originalSizes: [URL: Int64] = [:]
    var estimatedSizes: [URL: Int64] = [:]
    var isEstimating = false
    var estimationFailed = false
    var isProcessing = false { didSet { ProcessingActivity.setActive(isProcessing, owner: ObjectIdentifier(self)) } }
    var progress: Double = 0
    var currentFileName = ""
    var results: [CompressionResult] = []
    var successMessage: String?
    var errorMessage: String?
    private var estimationTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
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
        guard let url = selectedImages.first, let size = try? ImageCodec.dimensions(at: url) else { return 1 }
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
        let svc = ImageCompressionService()
        for url in selectedImages {
            do {
                try ImageCodec.validateStaticImage(at: url)
                _ = try svc.outputType(for: outputFormat, originalURL: url)
                _ = try ImageCodec.outputSize(original: ImageCodec.dimensions(at: url), maxDimension: effectiveMaxDimension,
                                              targetSize: customSize, fitWithin: boundingSize)
            } catch { return error.localizedDescription }
        }
        return nil
    }
    var canExecute: Bool { !selectedImages.isEmpty && !isProcessing && validationMessage == nil }
    var hasLargeFiles: Bool { originalSizes.values.contains { $0 > 50_000_000 } }
    var largeFileWarning: String? { hasLargeFiles ? "包含超过 50MB 的图片，处理可能需要较长时间" : nil }
    var smallFileNote: String? {
        outputFormat == .png ? "PNG 不减少颜色层次。仅重新编码可能不会变小；缩小尺寸或选择 JPG 可进一步减小体积。" : "转换格式或调整尺寸后，文件可能变大。结果会保留你选择的质量，不会擅自降级。"
    }

    func selectCompressionLevel(_ level: CompressionLevel) {
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
        guard !isProcessing else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = ImageCompressionService.supportedFormats
        if panel.runModal() == .OK { addImages(from: panel.urls) }
    }
    func removeImage(url: URL) {
        guard !isProcessing else { return }
        selectedImages.removeAll { $0 == url }
        originalSizes.removeValue(forKey: url)
        results = []
        refreshEstimates()
    }
    func moveImages(from source: IndexSet, to destination: Int) {
        guard !isProcessing else { return }
        selectedImages.move(fromOffsets: source, toOffset: destination)
        results = []
    }
    func addImages(from urls: [URL]) {
        guard !isProcessing else { return }
        var rejected: [String] = []
        let wasEmpty = selectedImages.isEmpty
        for url in urls where !selectedImages.contains(url) {
            guard url.isFileURL, let type = try? ImageCodec.sourceType(at: url),
                  ImageCompressionService.supportedFormats.contains(where: { type.conforms(to: $0) }),
                  (try? ImageCodec.dimensions(at: url)) != nil else {
                rejected.append(url.lastPathComponent); continue
            }
            selectedImages.append(url)
            originalSizes[url] = FileUtils.fileSize(of: url)
        }
        if wasEmpty, let first = selectedImages.first, let size = try? ImageCodec.dimensions(at: first) {
            aspectWidth = String(Int(size.width)); aspectHeight = String(Int(size.height))
        }
        results = []
        successMessage = nil
        errorMessage = rejected.isEmpty ? nil : "无法读取：" + rejected.joined(separator: "、")
        refreshEstimates()
    }
    func refreshEstimates() {
        estimationTask?.cancel()
        estimatedSizes = [:]
        isEstimating = false; estimationFailed = false
        let id = UUID(); estimateID = id
        guard !selectedImages.isEmpty, !isProcessing, validationMessage == nil else { return }
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
        isProcessing = true; progress = 0; results = []; successMessage = nil; errorMessage = nil
        let urls = selectedImages, q = effectiveQuality, fmt = outputFormat
        let maxDim = effectiveMaxDimension, target = customSize, box = boundingSize
        let update: @MainActor @Sendable (Double, String) -> Void = { [weak self] progress, name in
            self?.progress = progress
            self?.currentFileName = name
        }
        processingTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                var output: [CompressionResult] = [], errors: [String] = []
                for (index, url) in urls.enumerated() {
                    if Task.isCancelled { break }
                    await update(Double(index) / Double(urls.count), url.lastPathComponent)
                    do {
                        let type = try ImageCompressionService().outputType(for: fmt, originalURL: url)
                        let dir = try CacheManager.makeTaskDirectory(in: CacheManager.imageCacheDirectory)
                        let name = url.deletingPathExtension().lastPathComponent + "_处理." + (type.preferredFilenameExtension ?? "png")
                        let dest = dir.appendingPathComponent(name)
                        try await ImageCompressionWorker.shared.compress(url: url, quality: q, maxDimension: maxDim,
                            outputFormat: fmt, outputURL: dest, targetSize: target, fitWithin: box)
                        let result = CompressionResult(originalURL: url, compressedURL: dest,
                            originalSize: FileUtils.fileSize(of: url), compressedSize: FileUtils.fileSize(of: dest))
                        output.append(result)
                    } catch {
                        if Task.isCancelled { break }
                        errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                    await update(Double(index + 1) / Double(urls.count), url.lastPathComponent)
                }
                return (output, errors)
            }
            let (output, errors) = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
            guard let self else { return }
            self.results = output; self.isProcessing = false
            // 完成后直接采用实际字节数，覆盖导出前的计算结果。
            for result in output {
                self.originalSizes[result.originalURL] = result.originalSize
                self.estimatedSizes[result.originalURL] = result.compressedSize
            }
            self.estimationFailed = !self.hasCompleteEstimate && !errors.isEmpty
            self.successMessage = "\(Task.isCancelled ? "已停止" : "处理完成")：\(output.count) 张成功，\(errors.count) 张失败"
            self.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
            if !output.isEmpty {
                HistoryService().addRecord(toolName: "图片处理", operationType: "压缩与尺寸调整", fileCount: output.count,
                    inputFileNames: output.map { $0.originalURL.lastPathComponent }, status: errors.isEmpty ? "成功" : "部分成功",
                    inputSize: output.reduce(0) { $0 + $1.originalSize }, outputSize: output.reduce(0) { $0 + $1.compressedSize },
                    descriptionText: self.successMessage ?? "处理完成")
            }
        }
    }
    func cancelProcessing() { processingTask?.cancel() }
    func saveResults() {
        guard !isProcessing, !results.isEmpty else { return }
        let urls = results.map(\.compressedURL)
        Task {
            isProcessing = true
            defer { isProcessing = false }
            if let report = await ResultExporter.save(urls) {
                successMessage = report.message
                errorMessage = report.errors.isEmpty ? nil : report.errors.joined(separator: "\n")
            }
        }
    }
}
