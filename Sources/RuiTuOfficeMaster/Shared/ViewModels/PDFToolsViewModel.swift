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

struct PDFResultItem: Identifiable, Sendable {
    let id = UUID()
    let originalURL: URL
    let outputURL: URL
    let originalSize: Int64
    let outputSize: Int64
    let operationDescription: String

    var changePercent: Int {
        guard originalSize > 0 else { return 0 }
        return Int((1 - Double(outputSize) / Double(originalSize)) * 100)
    }
    var changeText: String { changePercent >= 0 ? "减少 \(changePercent)%" : "增加 \(-changePercent)%" }

}

// MARK: - PDF 工具 ViewModel

@MainActor @Observable
final class PDFToolsViewModel {
    typealias Processor = @Sendable (PDFProcessingJob, PDFBatchConfiguration, PDFStopToken) async throws -> [PDFResultItem]

    var selectedTool: PDFTool = .merge { didSet { if oldValue != selectedTool { settingsChanged(filterFiles: true); refreshSplitPreview() } } }
    var selectedFiles: [URL] = [] { didSet { if oldValue != selectedFiles { settingsChanged(); refreshSplitPreview() } } }
    let splitPreview = PDFSplitPreviewViewModel()
    var originalSizes: [URL: Int64] = [:]
    var splitRangesText = "" { didSet { if oldValue != splitRangesText { settingsChanged() } } }
    var userPassword = "" { didSet { if oldValue != userPassword { settingsChanged() } } }
    var ownerPassword = "" { didSet { if oldValue != ownerPassword { settingsChanged() } } }
    var allowPrinting = true { didSet { if oldValue != allowPrinting { settingsChanged() } } }
    var allowCopying = true { didSet { if oldValue != allowCopying { settingsChanged() } } }
    var watermarkUIType: WatermarkUIType = .text { didSet { if oldValue != watermarkUIType { settingsChanged() } } }
    var watermarkText = "机密" { didSet { if oldValue != watermarkText { settingsChanged() } } }
    var watermarkFontSize: CGFloat = 60 { didSet { if oldValue != watermarkFontSize { settingsChanged() } } }
    var watermarkRotation: Double = -45 { didSet { if oldValue != watermarkRotation { settingsChanged() } } }
    var watermarkOpacity: Double = 0.3 { didSet { if oldValue != watermarkOpacity { settingsChanged() } } }
    var watermarkImageURL: URL? { didSet { if oldValue != watermarkImageURL { settingsChanged() } } }
    var conversionDirection: ConversionDirection = .wordToPDF { didSet { if oldValue != conversionDirection { settingsChanged(filterFiles: true) } } }

    private(set) var isProcessing = false { didSet { ProcessingActivity.setActive(isProcessing, owner: ObjectIdentifier(self)) } }
    private(set) var isSaving = false { didSet { ProcessingActivity.setActive(isSaving, owner: ObjectIdentifier(self)) } }
    var progress: Double = 0
    private(set) var currentFileName = ""
    private(set) var entries: [PDFBatchEntry] = []
    private(set) var results: [PDFResultItem] = []
    private(set) var cancellationRequested = false
    private(set) var wasStopped = false
    var successMessage: String?
    var errorMessage: String?

    @ObservationIgnored private var configuration: PDFBatchConfiguration?
    @ObservationIgnored private var configurationIsCurrent = true
    @ObservationIgnored private var stopToken = PDFStopToken()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let processor: Processor

    init(processor: @escaping Processor = { job, config, stop in
        try PDFBatchProcessor.process(job, configuration: config, stop: stop)
    }) { self.processor = processor }

    var isBusy: Bool { isProcessing || isSaving }
    var fileCountText: String { "已选择 \(selectedFiles.count) 个文件" }
    var originalTotalSizeText: String { FileUtils.formatSize(selectedFiles.reduce(0) { $0 + (originalSizes[$1] ?? 0) }) }
    var succeededCount: Int { entries.filter { $0.state == .succeeded }.count }
    var failedCount: Int { entries.filter { $0.state == .failed }.count }
    var unfinishedCount: Int { entries.count - succeededCount - failedCount }
    var retryCount: Int { entries.filter { $0.state.canRetry }.count }
    var canRetry: Bool { !isBusy && configurationIsCurrent && retryCount > 0 }
    var isMergeBatch: Bool { configuration == .merge }
    var batchSummary: String { "成功 \(succeededCount) 项 · 失败 \(failedCount) 项 · 未完成 \(unfinishedCount) 项" }
    var canExecute: Bool {
        guard !selectedFiles.isEmpty, !isBusy else { return false }
        switch selectedTool {
        case .merge: return selectedFiles.count >= 2
        case .split: return splitPreview.isReady && splitPreview.sourceIsCurrent && splitRangeError == nil && !parsedRanges.isEmpty
        case .encrypt: return !userPassword.isEmpty && (ownerPassword.isEmpty || ownerPassword != userPassword)
        case .watermark: return watermarkUIType == .image ? watermarkImageURL != nil : !watermarkText.isEmpty
        case .conversion: return true
        }
    }
    var allowedContentTypes: [UTType] {
        selectedTool == .conversion ? (conversionDirection == .wordToPDF ? DocumentConversionService.wordFormats : [.pdf]) : [.pdf]
    }
    var parsePageRangesForDisplay: [String] {
        parsedRanges.map { $0.start == $0.end ? "第\($0.start)页" : "第\($0.start)-\($0.end)页" }
    }
    var splitRangeError: String? {
        guard selectedTool == .split else { return nil }
        guard selectedFiles.count == 1 else { return "拆分一次处理一份 PDF，请只保留要拆分的文档。" }
        if let error = splitPreview.documentError { return error }
        guard let count = splitPreview.pageCount, splitPreview.isReady else { return nil }
        guard splitPreview.sourceIsCurrent else { return "文件已变化，请重新加载预览并确认页码范围。" }
        guard !splitRangesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do { _ = try PageRangeParser.parse(splitRangesText, pageCount: count); return nil }
        catch {
            let example = count == 1 ? "1" : (count < 4 ? "1-\(count)" : "1-3, \(count)")
            return "文档共 \(count) 页，请输入 1–\(count) 内的页码或范围，例如 \(example)。范围起始页不能大于结束页。"
        }
    }
    var splitPreviewRanges: [SplitRange] { parsedRanges }
    var splitOutputPageCount: Int { parsedRanges.reduce(0) { $0 + $1.end - $1.start + 1 } }
    var currentPreviewPageIsIncluded: Bool {
        parsedRanges.contains { ($0.start...$0.end).contains(splitPreview.currentPage) }
    }
    private var parsedRanges: [SplitRange] {
        guard selectedFiles.count == 1, splitPreview.selectedURL == selectedFiles.first,
              splitPreview.isReady, let count = splitPreview.pageCount else { return [] }
        return (try? PageRangeParser.parse(splitRangesText, pageCount: count)) ?? []
    }
    private func refreshSplitPreview() {
        splitPreview.setFiles(selectedTool == .split ? selectedFiles : [])
    }
    private func accepts(_ url: URL) -> Bool {
        // File metadata may have no type identifier (for example newly-created files).
        // Accept supported extensions here; the actual parser validates the document per entry.
        let extensions: Set<String> = selectedTool == .conversion && conversionDirection == .wordToPDF ? ["doc", "docx"] : ["pdf"]
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
    private func settingsChanged(filterFiles: Bool = false) {
        configurationIsCurrent = false
        guard !isBusy else { return }
        entries = []; results = []; configuration = nil; progress = 0; currentFileName = ""
        successMessage = nil; errorMessage = nil; wasStopped = false
        if filterFiles { selectedFiles = selectedFiles.filter { accepts($0) } }
    }
    func addFiles(from urls: [URL]) {
        guard !isBusy else { return }
        var seen = Set(selectedFiles.map { $0.standardizedFileURL })
        let added = urls.filter { accepts($0) && seen.insert($0.standardizedFileURL).inserted }
        guard !added.isEmpty else { return }
        selectedFiles.append(contentsOf: added)
        for url in added { originalSizes[url] = FileUtils.fileSize(of: url) }
    }
    func removeFile(url: URL) {
        guard !isBusy else { return }
        selectedFiles.removeAll { $0 == url }; originalSizes.removeValue(forKey: url)
    }
    func moveFiles(from source: IndexSet, to destination: Int) {
        guard !isBusy else { return }
        selectedFiles.move(fromOffsets: source, toOffset: destination)
    }
    func clearFiles() {
        guard !isBusy else { return }
        selectedFiles = []; originalSizes = [:]
    }

    func execute() {
        if selectedTool == .split, splitPreview.isReady, !splitPreview.sourceIsCurrent {
            errorMessage = "文件已变化，请重新加载预览并确认页码范围。"
            return
        }
        guard canExecute else { return }
        let config: PDFBatchConfiguration
        switch selectedTool {
        case .merge: config = .merge
        case .split: config = .split
        case .encrypt: config = .encrypt(EncryptionConfig(userPassword: userPassword, ownerPassword: ownerPassword, allowPrinting: allowPrinting, allowCopying: allowCopying))
        case .watermark:
            if watermarkUIType == .image, let url = watermarkImageURL { config = .watermark(.image(url, opacity: watermarkOpacity)) }
            else { config = .watermark(.text(watermarkText, size: watermarkFontSize, rotation: watermarkRotation, opacity: watermarkOpacity)) }
        case .conversion: config = .conversion(conversionDirection)
        }
        configuration = config; configurationIsCurrent = true
        if config == .split, let url = selectedFiles.first {
            entries = parsedRanges.map { PDFBatchEntry(sourceURL: url, range: $0) }
        } else { entries = selectedFiles.map { PDFBatchEntry(sourceURL: $0, range: nil) } }
        results = []
        start(config)
    }
    func retryUnfinished() {
        guard canRetry, let config = configuration else { return }
        for index in entries.indices where entries[index].state.canRetry {
            entries[index].state = .waiting; entries[index].error = nil
        }
        start(config)
    }
    func retryEntry(_ id: UUID) {
        guard canRetry, let config = configuration, config != .merge,
              let index = entries.firstIndex(where: { $0.id == id }), entries[index].state.canRetry else { return }
        entries[index].state = .waiting; entries[index].error = nil
        start(config)
    }
    func stopProcessing() {
        guard isProcessing, !cancellationRequested else { return }
        cancellationRequested = true; stopToken.requestStop()
    }
    private func start(_ config: PDFBatchConfiguration) {
        for entry in entries { originalSizes[entry.sourceURL] = PDFBatchProcessor.freshFileSize(entry.sourceURL) }
        cancellationRequested = false; wasStopped = false; stopToken = PDFStopToken()
        successMessage = nil; errorMessage = nil; isProcessing = true
        updateProgress()
        task = Task { [self] in
            if config == .merge { await runMerge(config) } else { await runFiles(config) }
            finish(config)
        }
    }
    private func runFiles(_ config: PDFBatchConfiguration) async {
        let process = processor; let stop = stopToken
        for index in entries.indices where entries[index].state == .waiting {
            if cancellationRequested { break }
            entries[index].state = .processing
            currentFileName = entries[index].title
            let job = PDFProcessingJob(sources: [entries[index].sourceURL], range: entries[index].range)
            do {
                let output = try await Task.detached(priority: .userInitiated) { try await process(job, config, stop) }.value
                results.append(contentsOf: output)
                entries[index].state = .succeeded
            } catch is CancellationError {
                entries[index].state = .stopped; cancellationRequested = true
            } catch {
                entries[index].state = .failed; entries[index].error = error.localizedDescription
            }
            updateProgress()
        }
    }
    private func runMerge(_ config: PDFBatchConfiguration) async {
        for index in entries.indices {
            if cancellationRequested { break }
            entries[index].state = .processing; currentFileName = "检查：" + entries[index].title
            let url = entries[index].sourceURL
            do {
                try await Task.detached(priority: .userInitiated) { try PDFService().validate(url: url) }.value
                entries[index].state = .ready
            } catch {
                entries[index].state = .failed; entries[index].error = error.localizedDescription
            }
            progress = Double(index + 1) / Double(entries.count) * 0.5
        }
        guard !cancellationRequested, failedCount == 0 else {
            for index in entries.indices where entries[index].state == .ready { entries[index].state = .blocked }
            return
        }
        currentFileName = "正在合并 \(entries.count) 个文件…"
        let job = PDFProcessingJob(sources: entries.map(\.sourceURL), range: nil)
        let process = processor; let stop = stopToken
        do {
            let output = try await Task.detached(priority: .userInitiated) { try await process(job, config, stop) }.value
            results = output
            for index in entries.indices { entries[index].state = .succeeded }
            progress = 1
        } catch is CancellationError {
            cancellationRequested = true
            for index in entries.indices { entries[index].state = .stopped }
        } catch {
            for index in entries.indices { entries[index].state = .failed; entries[index].error = error.localizedDescription }
        }
    }
    private func updateProgress() {
        progress = entries.isEmpty ? 0 : Double(succeededCount + failedCount) / Double(entries.count)
    }
    private func finish(_ config: PDFBatchConfiguration) {
        for index in entries.indices where entries[index].state == .waiting || entries[index].state == .processing {
            entries[index].state = .stopped
        }
        wasStopped = cancellationRequested && unfinishedCount > 0
        isProcessing = false; task = nil; currentFileName = ""
        if config != .merge { updateProgress() }
        let errors = entries.compactMap { entry in entry.error.map { "\(entry.title)：\($0)" } }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        successMessage = (wasStopped ? "已停止：" : "处理结束：") + batchSummary
        if !configurationIsCurrent { successMessage = (successMessage ?? "") + "；结果来自开始处理时的设置" }
        HistoryService().addRecord(toolName: "PDF 工具", operationType: config.title,
            fileCount: Set(entries.map(\.sourceURL)).count, inputFileNames: entries.map { $0.sourceURL.lastPathComponent },
            status: wasStopped ? "已停止" : (failedCount > 0 ? (results.isEmpty ? "失败" : "部分成功") : (unfinishedCount > 0 ? "未完成" : "成功")),
            inputSize: Set(entries.map(\.sourceURL)).reduce(Int64(0)) { $0 + PDFBatchProcessor.freshFileSize($1) },
            outputSize: results.reduce(0) { $0 + $1.outputSize }, descriptionText: batchSummary)
    }

#if os(macOS)
    func selectWatermarkImage() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, UTType(filenameExtension: "heic") ?? .image]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        Task { if await FileDialogs.response(to: panel) == .OK { watermarkImageURL = panel.url } }
    }
    func selectFiles() {
        guard !isBusy else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        Task { if await FileDialogs.response(to: panel) == .OK { addFiles(from: panel.urls) } }
    }
    func saveResults() {
        guard !isBusy, !results.isEmpty else { return }
        let urls = results.map(\.outputURL)
        isSaving = true
        Task {
            defer { isSaving = false }
            if let report = await ResultExporter.save(urls) {
                successMessage = report.message
                errorMessage = report.errors.isEmpty ? nil : report.errors.joined(separator: "\n")
            }
        }
    }
#endif
}
