import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif

// MARK: - PDF 工具枚举

enum PDFTool: String, CaseIterable {
    case merge = "合并"
    case split = "拆分"
    case encrypt = "加密"
    case watermark = "水印"
    case conversion = "格式转换"
}

// MARK: - 水印 UI 类型

enum WatermarkUIType: String, CaseIterable {
    case text = "文字水印"
    case image = "图片水印"
}

// MARK: - PDF 结果项

struct PDFResultItem: Identifiable {
    let id = UUID()
    let originalURL: URL
    let outputURL: URL
    let originalSize: Int64
    let outputSize: Int64
    let operationDescription: String

    var savedPercent: String {
        guard originalSize > 0 else { return "0" }
        let saved = Double(originalSize - outputSize) / Double(originalSize) * 100
        return String(format: "%.0f", saved)
    }
}

// MARK: - PDF 工具 ViewModel

@Observable
final class PDFToolsViewModel: @unchecked Sendable {

    // MARK: 工具选择

    var selectedTool: PDFTool = .merge

    // MARK: 文件选择

    var selectedFiles: [URL] = []
    var originalSizes: [URL: Int64] = [:]

    // MARK: 拆分参数

    var splitRangesText: String = ""

    // MARK: 加密参数

    var userPassword: String = ""
    var ownerPassword: String = ""
    var allowPrinting: Bool = true
    var allowCopying: Bool = true

    // MARK: 水印参数

    var watermarkUIType: WatermarkUIType = .text
    var watermarkText: String = "机密"
    var watermarkFontSize: CGFloat = 60
    var watermarkRotation: Double = -45
    var watermarkOpacity: Double = 0.3
    var watermarkImageURL: URL?

    // MARK: 格式转换参数

    var conversionDirection: ConversionDirection = .wordToPDF

    // MARK: 处理状态

    var isProcessing = false { didSet { ProcessingActivity.setActive(isProcessing, owner: ObjectIdentifier(self)) } }
    var progress: Double = 0
    var currentFileName: String = ""

    // MARK: 结果

    var results: [PDFResultItem] = []
    var successMessage: String?
    var errorMessage: String?

    // MARK: 服务

    private let pdfService = PDFService()
    private let conversionService = DocumentConversionService()

    // MARK: 计算属性

    var fileCountText: String {
        "已选择 \(selectedFiles.count) 个文件"
    }

    var originalTotalSizeText: String {
        let total = selectedFiles.reduce(0) { $0 + (originalSizes[$1] ?? 0) }
        return FileUtils.formatSize(total)
    }

    var canExecute: Bool {
        guard !selectedFiles.isEmpty, !isProcessing else { return false }
        switch selectedTool {
        case .merge:
            return selectedFiles.count >= 2
        case .split:
            return selectedFiles.count == 1 && !parsePageRangesForDisplay.isEmpty
        case .encrypt:
            return !userPassword.isEmpty
        case .watermark:
            if case .image = watermarkUIType {
                return watermarkImageURL != nil
            }
            return !watermarkText.isEmpty
        case .conversion:
            return true
        }
    }

    /// 当前工具允许的文件类型
    var allowedContentTypes: [UTType] {
        switch selectedTool {
        case .conversion:
            return conversionDirection == .wordToPDF ? DocumentConversionService.wordFormats : DocumentConversionService.pdfFormats
        default:
            return PDFService.supportedFormats
        }
    }

    /// 页码范围预览（用于 UI 显示）
    var parsePageRangesForDisplay: [String] {
        let ranges = parsePageRanges(splitRangesText, pageCount: selectedFiles.first.map { PDFService().pageCount(of: $0) } ?? 0)
        return ranges.map { $0.start == $0.end ? "第\($0.start)页" : "第\($0.start)-\($0.end)页" }
    }

    // MARK: 文件选择

#if os(macOS)
    @MainActor
    func selectWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, UTType(filenameExtension: "heic") ?? .image]

        if panel.runModal() == .OK, let url = panel.urls.first {
            watermarkImageURL = url
        }
    }
#endif

#if os(macOS)
    @MainActor
    func selectFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedContentTypes

        if panel.runModal() == .OK {
            addFiles(from: panel.urls)
        }
    }
#endif

    func addFiles(from urls: [URL]) {
        guard !isProcessing else { return }
        let newURLs = urls.filter { url in
            guard url.isFileURL, !selectedFiles.contains(url) else { return false }
            guard let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
                  let type = UTType(uti) else { return false }
            return allowedContentTypes.contains { type.conforms(to: $0) }
        }
        selectedFiles.append(contentsOf: newURLs)
        for url in newURLs {
            originalSizes[url] = FileUtils.fileSize(of: url)
        }
        clearMessages()
    }

    // MARK: 管理文件

    func removeFile(url: URL) {
        guard !isProcessing else { return }
        guard let index = selectedFiles.firstIndex(of: url) else { return }
        selectedFiles.remove(at: index)
        originalSizes.removeValue(forKey: url)
        results.removeAll { $0.originalURL == url }
    }

    func moveFiles(from source: IndexSet, to destination: Int) {
        guard !isProcessing else { return }
        selectedFiles.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: 执行

    func execute() {
        guard canExecute else { return }

        isProcessing = true
        progress = 0
        results = []
        clearMessages()

        switch selectedTool {
        case .merge:
            executeMerge()
        case .split:
            executeSplit()
        case .encrypt:
            executeEncrypt()
        case .watermark:
            executeWatermark()
        case .conversion:
            executeConversion()
        }
    }

    // MARK: 合并

    private func executeMerge() {
        let files = selectedFiles
        let sizes = originalSizes
        guard let firstFile = files.first else { return }

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let outputDir = CacheManager.isolatedDirectory(in: CacheManager.documentCacheDirectory)
            let outputURL = outputDir.appendingPathComponent("合并文档.pdf")
            try? FileManager.default.removeItem(at: outputURL)

            do {
                try self.pdfService.merge(urls: files, outputURL: outputURL)
                let outSize = FileUtils.fileSize(of: outputURL)
                let totalOriginal = files.reduce(0) { $0 + (sizes[$1] ?? 0) }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isProcessing = false
                    self.progress = 1.0
                    self.results = [PDFResultItem(
                        originalURL: firstFile,
                        outputURL: outputURL,
                        originalSize: totalOriginal,
                        outputSize: outSize,
                        operationDescription: "合并 \(files.count) 个文件"
                    )]
                    self.successMessage = "成功合并 \(files.count) 个 PDF 文件"
                    HistoryService().addRecord(
                        toolName: "PDF 工具",
                        operationType: "合并",
                        fileCount: files.count,
                        inputFileNames: files.map { $0.lastPathComponent },
                        status: "成功",
                        inputSize: totalOriginal,
                        outputSize: outSize,
                        descriptionText: "合并 \(files.count) 个 PDF 文件"
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isProcessing = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: 拆分

    private func executeSplit() {
        guard let url = selectedFiles.first else { return }
        let ranges = parsePageRanges(splitRangesText, pageCount: pdfService.pageCount(of: url))
        guard !ranges.isEmpty else {
            errorMessage = "页码范围格式不正确，请使用「1-3, 5, 7-10」格式"
            isProcessing = false
            return
        }

        let sourceURL = url
        let originalSize = originalSizes[url] ?? 0

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            let outputDir = CacheManager.isolatedDirectory(in: CacheManager.documentCacheDirectory)
                .appendingPathComponent("split_\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            do {
                let urls = try self.pdfService.split(url: sourceURL, ranges: ranges, outputDir: outputDir)

                let items = urls.map { outURL in
                    PDFResultItem(
                        originalURL: sourceURL,
                        outputURL: outURL,
                        originalSize: originalSize,
                        outputSize: FileUtils.fileSize(of: outURL),
                        operationDescription: outURL.lastPathComponent
                    )
                }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isProcessing = false
                    self.progress = 1.0
                    self.results = items
                    self.successMessage = "成功拆分为 \(items.count) 个文件"
                    HistoryService().addRecord(
                        toolName: "PDF 工具",
                        operationType: "拆分",
                        fileCount: 1,
                        inputFileNames: [sourceURL.lastPathComponent],
                        status: "成功",
                        inputSize: originalSize,
                        outputSize: items.reduce(0) { $0 + $1.outputSize },
                        descriptionText: "将 PDF 拆分为 \(items.count) 个文件"
                    )
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isProcessing = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 解析页码范围字符串 "1-3, 5, 7-10"
    private func parsePageRanges(_ text: String, pageCount: Int) -> [SplitRange] {
        (try? PageRangeParser.parse(text, pageCount: pageCount)) ?? []
    }

    // MARK: 加密

    private func executeEncrypt() {
        let files = selectedFiles
        let config = EncryptionConfig(
            userPassword: userPassword,
            ownerPassword: ownerPassword,
            allowPrinting: allowPrinting,
            allowCopying: allowCopying
        )

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var items: [PDFResultItem] = []
            var errors: [String] = []

            for (i, url) in files.enumerated() {
                let originalName = (url.lastPathComponent as NSString).deletingPathExtension
                let outputURL = CacheManager.isolatedDirectory(in: CacheManager.documentCacheDirectory)
                    .appendingPathComponent("\(originalName)_加密.pdf")
                try? FileManager.default.removeItem(at: outputURL)

                do {
                    try self.pdfService.encrypt(url: url, config: config, outputURL: outputURL)
                    let originalSize = FileUtils.fileSize(of: url)
                    let outSize = FileUtils.fileSize(of: outputURL)
                    items.append(PDFResultItem(
                        originalURL: url,
                        outputURL: outputURL,
                        originalSize: originalSize,
                        outputSize: outSize,
                        operationDescription: "加密"
                    ))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }

                let prog = Double(i + 1) / Double(files.count)
                let name = url.lastPathComponent
                await MainActor.run { [weak self] in
                    self?.progress = prog
                    self?.currentFileName = name
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.progress = 1.0
                self.results = items
                self.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
                if errors.isEmpty {
                    self.successMessage = "成功加密 \(items.count) 个文件"
                } else {
                    self.successMessage = "成功 \(items.count) 个，\(errors.count) 个失败"
                }
                if !items.isEmpty {
                    HistoryService().addRecord(
                        toolName: "PDF 工具",
                        operationType: "加密",
                        fileCount: files.count,
                        inputFileNames: files.map { $0.lastPathComponent },
                        status: errors.isEmpty ? "成功" : "部分成功",
                        inputSize: items.reduce(0) { $0 + $1.originalSize },
                        outputSize: items.reduce(0) { $0 + $1.outputSize },
                        descriptionText: "加密 \(items.count) 个 PDF 文件"
                    )
                }
            }
        }
    }

    // MARK: 水印

    private func executeWatermark() {
        let files = selectedFiles
        let wmType: WatermarkType

        switch watermarkUIType {
        case .text:
            wmType = .text(watermarkText, fontSize: watermarkFontSize, color: CGColor(gray: 0.5, alpha: 1.0), rotation: watermarkRotation, opacity: watermarkOpacity)
        case .image:
            guard let imgURL = watermarkImageURL else {
                isProcessing = false
                errorMessage = "请先选择水印图片"
                return
            }
            wmType = .image(imgURL, scale: 0.3, opacity: watermarkOpacity)
        }

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var items: [PDFResultItem] = []
            var errors: [String] = []

            for (i, url) in files.enumerated() {
                let originalName = (url.lastPathComponent as NSString).deletingPathExtension
                let outputURL = CacheManager.isolatedDirectory(in: CacheManager.documentCacheDirectory)
                    .appendingPathComponent("\(originalName)_水印.pdf")
                try? FileManager.default.removeItem(at: outputURL)

                do {
                    try self.pdfService.addWatermark(url: url, type: wmType, outputURL: outputURL)
                    let originalSize = FileUtils.fileSize(of: url)
                    let outSize = FileUtils.fileSize(of: outputURL)
                    items.append(PDFResultItem(
                        originalURL: url,
                        outputURL: outputURL,
                        originalSize: originalSize,
                        outputSize: outSize,
                        operationDescription: "水印"
                    ))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }

                let prog = Double(i + 1) / Double(files.count)
                let name = url.lastPathComponent
                await MainActor.run { [weak self] in
                    self?.progress = prog
                    self?.currentFileName = name
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.progress = 1.0
                self.results = items
                self.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
                if errors.isEmpty {
                    self.successMessage = "成功为 \(items.count) 个文件添加水印"
                } else {
                    self.successMessage = "成功 \(items.count) 个，\(errors.count) 个失败"
                }
                if !items.isEmpty {
                    HistoryService().addRecord(
                        toolName: "PDF 工具",
                        operationType: "水印",
                        fileCount: files.count,
                        inputFileNames: files.map { $0.lastPathComponent },
                        status: errors.isEmpty ? "成功" : "部分成功",
                        inputSize: items.reduce(0) { $0 + $1.originalSize },
                        outputSize: items.reduce(0) { $0 + $1.outputSize },
                        descriptionText: "为 \(items.count) 个 PDF 文件添加水印"
                    )
                }
            }
        }
    }

    // MARK: 格式转换

    private func executeConversion() {
        let files = selectedFiles
        let direction = conversionDirection

        Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var items: [PDFResultItem] = []
            var errors: [String] = []

            for (i, url) in files.enumerated() {
                let originalName = (url.lastPathComponent as NSString).deletingPathExtension
                let outputExt = direction == .wordToPDF ? "pdf" : "docx"
                let outputURL = CacheManager.isolatedDirectory(in: CacheManager.documentCacheDirectory)
                    .appendingPathComponent("\(originalName)_转换.\(outputExt)")
                try? FileManager.default.removeItem(at: outputURL)

                do {
                    switch direction {
                    case .wordToPDF:
                        try self.conversionService.wordToPDF(url: url, outputURL: outputURL)
                    case .pdfToWord:
                        try self.conversionService.pdfToWord(url: url, outputURL: outputURL)
                    }
                    let originalSize = FileUtils.fileSize(of: url)
                    let outSize = FileUtils.fileSize(of: outputURL)
                    items.append(PDFResultItem(
                        originalURL: url,
                        outputURL: outputURL,
                        originalSize: originalSize,
                        outputSize: outSize,
                        operationDescription: direction.rawValue
                    ))
                } catch {
                    errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }

                let prog = Double(i + 1) / Double(files.count)
                let name = url.lastPathComponent
                await MainActor.run { [weak self] in
                    self?.progress = prog
                    self?.currentFileName = name
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.progress = 1.0
                self.results = items
                self.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
                if errors.isEmpty {
                    self.successMessage = "成功转换 \(items.count) 个文件"
                } else {
                    self.successMessage = "成功转换 \(items.count) 个，\(errors.count) 个失败"
                }
                if !items.isEmpty {
                    HistoryService().addRecord(
                        toolName: "PDF 工具",
                        operationType: direction.rawValue,
                        fileCount: files.count,
                        inputFileNames: files.map { $0.lastPathComponent },
                        status: errors.isEmpty ? "成功" : "部分成功",
                        inputSize: items.reduce(0) { $0 + $1.originalSize },
                        outputSize: items.reduce(0) { $0 + $1.outputSize },
                        descriptionText: "转换 \(items.count) 个文件"
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
        let urls = results.map(\.outputURL)
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
