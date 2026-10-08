import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 视频压缩结果

struct VideoCompressionItem: Identifiable {
    let id = UUID()
    let originalURL: URL
    let compressedURL: URL
    let originalSize: Int64
    let compressedSize: Int64

    /// 正数表示减少，负数表示增加
    var savedPercent: Int {
        guard originalSize > 0 else { return 0 }
        return Int((1 - Double(compressedSize) / Double(originalSize)) * 100)
    }
    var changeText: String { savedPercent >= 0 ? "减少 \(savedPercent)%" : "增加 \(-savedPercent)%" }
}

// MARK: - 视频压缩 ViewModel

@Observable
final class VideoCompressionViewModel: @unchecked Sendable {

    // MARK: 视频选择
    var selectedVideos: [URL] = []
    var originalSizes: [URL: Int64] = [:]

    // MARK: 压缩参数
    var quality: VideoQuality = .medium
    var resolution: VideoResolution = .original
    var codec: VideoCodec = .h264
    var outputFormat: VideoOutputFormat = .mp4

    // MARK: 预估
    var estimatedSizes: [URL: Int64] = [:]

    // MARK: 处理状态
    var isProcessing = false { didSet { ProcessingActivity.setActive(isProcessing, owner: ObjectIdentifier(self)) } }
    var progress: Double = 0
    var currentFileName = ""

    // MARK: 结果
    var results: [VideoCompressionItem] = []
    var successMessage: String?
    var errorMessage: String?

    private let service = VideoCompressionService()
    private var estimationTask: Task<Void, Never>?

    // MARK: 计算属性

    var videoCountText: String {
        "已选择 \(selectedVideos.count) 个视频"
    }

    var originalTotalSizeText: String {
        let total = selectedVideos.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        return FileUtils.formatSize(total)
    }

    /// 预估压缩后总大小
    var estimatedSizeText: String {
        estimatedSizes.count == selectedVideos.count && estimatedTotalSize > 0 ? FileUtils.formatSize(estimatedTotalSize) : "待估算"
    }

    /// 预估节省百分比
    var estimatedSavedPercent: Int {
        let totalOriginal = selectedVideos.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        guard totalOriginal > 0 else { return 0 }
        guard estimatedSizes.count == selectedVideos.count, estimatedTotalSize > 0 else { return 0 }
        return Int((1 - Double(estimatedTotalSize) / Double(totalOriginal)) * 100)
    }

    var estimatedChangeText: String {
        guard estimatedSizeText != "待估算" else { return "待估算" }
        let value = estimatedSavedPercent
        return value >= 0 ? "约减少 \(value)%" : "约增加 \(-value)%"
    }
    private var estimatedTotalSize: Int64 {
        selectedVideos.reduce(0) { $0 + (estimatedSizes[$1] ?? 0) }
    }

    /// 单个视频预估压缩后大小文本
    func estimatedSizeText(for url: URL) -> String {
        FileUtils.formatSize(estimatedSizes[url] ?? 0)
    }

    /// 单个视频预估节省百分比
    func estimatedSavedPercent(for url: URL) -> Int {
        let orig = originalSizes[url] ?? 0
        let est = estimatedSizes[url] ?? 0
        guard orig > 0, est > 0 else { return 0 }
        return Int((1 - Double(est) / Double(orig)) * 100)
    }

    /// 小文件 / 大文件 / 无压缩空间提示
    var smallFileNote: String? {
        let tiny = selectedVideos.filter { (originalSizes[$0] ?? 0) < 1_048_576 && (originalSizes[$0] ?? 0) > 0 }
        if !tiny.isEmpty {
            return "已选择 \(tiny.count) 个极小视频（<1MB），继续压缩空间有限"
        }
        let totalOrig = selectedVideos.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        let totalEst = estimatedTotalSize
        if totalOrig > 0 && totalEst > 0 && Double(totalEst) >= Double(totalOrig) * 0.95 {
            return "预估体积接近或超过原文件。可以尝试降低质量或分辨率；实际结果可能变大。"
        }
        if totalOrig > 500_000_000 {
            return "总文件较大（>500MB），耗时取决于视频时长、编码格式和设备性能"
        }
        return nil
    }

    var canExecute: Bool {
        !selectedVideos.isEmpty && !isProcessing
    }

    // MARK: 视频选择

#if os(macOS)
    @MainActor
    func selectVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = VideoCompressionService.supportedFormats

        if panel.runModal() == .OK {
            addVideos(from: panel.urls)
        }
    }
#endif

    func addVideos(from urls: [URL]) {
        guard !isProcessing else { return }
        let newURLs = urls.filter { url in
            guard url.isFileURL, !selectedVideos.contains(url) else { return false }
            guard let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
                  let type = UTType(uti) else { return false }
            return VideoCompressionService.supportedFormats.contains { type.conforms(to: $0) }
        }
        selectedVideos.append(contentsOf: newURLs)
        for url in newURLs {
            originalSizes[url] = FileUtils.fileSize(of: url)
        }
        refreshEstimates()
        clearMessages()
    }

    // MARK: 管理已选视频

    func removeVideo(url: URL) {
        guard !isProcessing else { return }
        guard let index = selectedVideos.firstIndex(of: url) else { return }
        selectedVideos.remove(at: index)
        originalSizes.removeValue(forKey: url)
        estimatedSizes.removeValue(forKey: url)
        results.removeAll { $0.originalURL == url }
    }

    // MARK: 刷新预估（基于目标码率×时长，仅供参考）

    func refreshEstimates() {
        estimationTask?.cancel()
        estimatedSizes = [:]
        guard !selectedVideos.isEmpty, !isProcessing else { return }
        estimationTask = Task { [weak self] in
            guard let self else { return }

            let q = self.quality
            let r = self.resolution
            let c = self.codec
            let urls = self.selectedVideos
            let svc = VideoCompressionService()
            var newEstimates: [URL: Int64] = [:]

            for url in urls {
                guard !Task.isCancelled else { return }
                newEstimates[url] = svc.estimateCompressedSize(
                    url: url, quality: q, resolution: r, codec: c
                )
            }

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.estimatedSizes = newEstimates
            }
        }
    }

    // MARK: 执行压缩

    func executeCompression() {
        guard canExecute else { return }

        isProcessing = true
        progress = 0
        results = []
        clearMessages()

        let videos = selectedVideos
        let q = quality
        let r = resolution
        let c = codec
        let fmt = outputFormat
        let sizes = originalSizes

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let svc = VideoCompressionService()
            var compressionResults: [VideoCompressionItem] = []
            var errors: [String] = []

            for url in videos {
                guard !Task.isCancelled else { break }

                let originalName = (url.lastPathComponent as NSString).deletingPathExtension
                let compressedName = "\(originalName)_compressed.\(fmt.fileExtension)"
                let outputDir = CacheManager.isolatedDirectory(in: CacheManager.mediaCacheDirectory)
                let outputURL = outputDir.appendingPathComponent(compressedName)
                try? FileManager.default.removeItem(at: outputURL)

                do {
                    let completedCount = compressionResults.count + errors.count
                    let totalCount = videos.count

                    try await svc.compress(
                        url: url, quality: q, resolution: r,
                        codec: c, outputFormat: fmt, outputURL: outputURL
                    ) { [weak self] prog in
                        Task { @MainActor [weak self] in
                            self?.progress = (Double(completedCount) + prog) / Double(totalCount)
                        }
                    }

                    let originalSize = sizes[url] ?? 0
                    let compressedSize = FileUtils.fileSize(of: outputURL)

                    compressionResults.append(VideoCompressionItem(
                        originalURL: url,
                        compressedURL: outputURL,
                        originalSize: originalSize,
                        compressedSize: compressedSize
                    ))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }

                let done = Double(compressionResults.count + errors.count)
                let total = Double(videos.count)
                let name = url.lastPathComponent
                await MainActor.run { [weak self] in
                    self?.progress = done / total
                    self?.currentFileName = name
                }
            }

            let finalResults = compressionResults
            let finalErrors = errors

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.progress = 1.0
                self.results = finalResults
                self.errorMessage = finalErrors.isEmpty ? nil : finalErrors.joined(separator: "\n")

                if finalErrors.isEmpty {
                    let totalIn = finalResults.reduce(0) { $0 + $1.originalSize }
                    let totalOut = finalResults.reduce(0) { $0 + $1.compressedSize }
                    let savedPct = totalIn > 0 ? Int((1 - Double(totalOut) / Double(totalIn)) * 100) : 0
                    if savedPct <= 0 && totalIn > 0 {
                        self.successMessage = "处理完成；输出体积未减小，已保留所选格式与质量"
                    } else {
                        self.successMessage = "成功压缩 \(finalResults.count) 个视频，节省 \(savedPct)% 空间"
                    }
                } else if finalResults.isEmpty {
                    self.errorMessage = finalErrors.joined(separator: "\n")
                } else {
                    self.successMessage = "成功压缩 \(finalResults.count) 个视频，\(finalErrors.count) 个失败"
                }

                // 历史记录
                if !finalResults.isEmpty {
                    let totalIn = finalResults.reduce(0) { $0 + $1.originalSize }
                    let totalOut = finalResults.reduce(0) { $0 + $1.compressedSize }
                    let savedPct = totalIn > 0 ? Int((1 - Double(totalOut) / Double(totalIn)) * 100) : 0
                    HistoryService().addRecord(
                        toolName: "视频压缩",
                        operationType: "批量压缩",
                        fileCount: finalResults.count,
                        inputFileNames: finalResults.map { $0.originalURL.lastPathComponent },
                        status: finalErrors.isEmpty ? "成功" : "部分成功",
                        inputSize: totalIn,
                        outputSize: totalOut,
                        descriptionText: "处理 \(finalResults.count) 个视频，" + (savedPct >= 0 ? "减少 \(savedPct)%" : "增加 \(-savedPct)%")
                    )
                }
            }
        }
    }

    // MARK: 保存结果

#if os(macOS)
    @MainActor
    func saveResults() {
        guard !isProcessing, !results.isEmpty else { return }
        let urls = results.map(\.compressedURL)
        Task { @MainActor in
            isProcessing = true
            defer { isProcessing = false }
            if let report = await ResultExporter.save(urls) {
                successMessage = report.message
                errorMessage = report.errors.isEmpty ? nil : report.errors.joined(separator: "\n")
            }
        }
    }
#endif

    private func clearMessages() {
        successMessage = nil
        errorMessage = nil
    }
}
