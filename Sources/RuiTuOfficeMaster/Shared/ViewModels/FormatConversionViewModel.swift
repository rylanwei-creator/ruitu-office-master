import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ConversionResultItem: Identifiable, Sendable {
    let id = UUID()
    let originalURL: URL
    let convertedURL: URL
    let originalSize: Int64
    let convertedSize: Int64
    let targetFormat: ConversionFormat
}

@MainActor @Observable
final class FormatConversionViewModel {
    var selectedFiles: [URL] = []
    var originalSizes: [URL: Int64] = [:]
    var targetFormat: ConversionFormat = .jpg { didSet { if oldValue != targetFormat { invalidateResults() } } }
    var isProcessing = false { didSet { ProcessingActivity.setActive(isProcessing, owner: ObjectIdentifier(self)) } }
    var isImporting = false
    var isSaving = false
    var progress: Double = 0
    var currentFileName = ""
    var results: [ConversionResultItem] = []
    var successMessage: String?
    var errorMessage: String?
    private(set) var taskID: UUID?
    private let taskManager: FileTaskManager
    private var importTask: Task<Void, Never>?
    init(taskManager: FileTaskManager = .shared) { self.taskManager = taskManager }
    deinit { ProcessingActivity.setActive(false, owner: ObjectIdentifier(self)) }
    var fileCountText: String { "已选择 \(selectedFiles.count) 个文件" }
    var originalTotalSizeText: String { FileUtils.formatSize(selectedFiles.reduce(0) { $0 + (originalSizes[$1] ?? 0) }) }
    var canExecute: Bool { !selectedFiles.isEmpty && !isProcessing && !isImporting && !isSaving }
    var messageColor: Color {
        if errorMessage != nil { return results.isEmpty ? AppColors.error : .orange }
        if let taskID, taskManager.record(taskID)?.state == .cancelled { return .orange }
        return AppColors.success
    }
    var messageIcon: String { messageColor == AppColors.success ? "checkmark.circle.fill" : "info.circle.fill" }
    var canRetry: Bool { taskID.map { taskManager.canRetry($0) } ?? false }

    func selectFiles() {
        guard !isProcessing, !isImporting, !isSaving else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowedContentTypes = FormatConversionService.supportedInputFormats
        Task { [weak self] in
            guard await FileDialogs.response(to: panel) == .OK else { return }
            self?.importFiles(from: panel.urls)
        }
    }
    // 供小批量程序调用与测试；界面统一使用后台导入。
    func addFiles(from urls: [URL]) {
        guard !isProcessing, !isImporting, !isSaving else { return }
        do { apply(try ImageFileImporter.collect(urls, excluding: selectedFiles)) }
        catch { errorMessage = error.localizedDescription }
    }
    func importFiles(from urls: [URL]) {
        guard !isProcessing, !isImporting, !isSaving else { return }
        isImporting = true; errorMessage = nil
        let excluded = selectedFiles
        importTask = Task { [weak self] in
            do {
                let report = try await ImageFileImporter.collectInBackground(urls, excluding: excluded)
                try Task.checkCancellation()
                self?.apply(report)
            } catch {
                self?.errorMessage = error is CancellationError ? "导入已停止，原列表保留" : error.localizedDescription
            }
            self?.isImporting = false
        }
    }
    func cancelImport() { importTask?.cancel() }
    private func apply(_ report: ImageImportReport) {
        invalidateResults()
        selectedFiles.append(contentsOf: report.images.map(\.url))
        for item in report.images { originalSizes[item.url] = item.size }
        errorMessage = report.message
        if report.duplicates > 0 { successMessage = "已跳过 \(report.duplicates) 个重复文件" }
    }
    func clearFiles() {
        guard !isProcessing, !isImporting, !isSaving else { return }
        selectedFiles = []; originalSizes = [:]; invalidateResults()
    }
    func removeFile(url: URL) {
        guard !isProcessing, !isImporting, !isSaving else { return }
        selectedFiles.removeAll { $0 == url }; originalSizes.removeValue(forKey: url); invalidateResults()
    }
    private func invalidateResults() {
        taskID = nil; results = []; successMessage = nil; errorMessage = nil; progress = 0
    }
    func executeConversion() {
        guard canExecute else { return }
        results = []; successMessage = nil; errorMessage = nil
        let fmt = targetFormat
        let id = taskManager.enqueue(tool: "格式转换", configuration: "转为 \(fmt.rawValue)", sources: selectedFiles) { url in
            let dir = try CacheManager.makeTaskDirectory(in: CacheManager.imageCacheDirectory)
            let destination = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_转换." + fmt.fileExtension)
            do {
                try await ImageCompressionWorker.shared.convert(url: url, format: fmt, outputURL: destination)
                return FileTaskOutput(url: destination, inputSize: FileUtils.fileSize(of: url), outputSize: FileUtils.fileSize(of: destination))
            } catch { try? FileManager.default.removeItem(at: dir); throw error }
        } onChange: { [weak self] record in
            guard self?.taskID == record.id else { return }
            self?.consume(record, format: fmt)
        }
        taskID = id
        if let record = taskManager.record(id) { consume(record, format: fmt) }
    }
    private func consume(_ record: FileTaskRecord, format: ConversionFormat) {
        isProcessing = record.state.isActive
        progress = record.progress
        currentFileName = record.cancellationRequested && record.state.isActive ? "正在停止，当前图片编码结束后退出…" : record.currentFile
        results = record.files.compactMap { item in
            guard let output = item.output, item.state == .completed else { return nil }
            return ConversionResultItem(originalURL: item.source, convertedURL: output.url, originalSize: output.inputSize, convertedSize: output.outputSize, targetFormat: format)
        }
        guard !record.state.isActive else { return }
        successMessage = record.summary
        errorMessage = record.files.compactMap { item in item.error.map { "\(item.source.lastPathComponent)：\($0)" } }.joined(separator: "\n")
        if errorMessage?.isEmpty == true { errorMessage = nil }
        HistoryService().addRecord(toolName: "格式转换", operationType: record.configuration, fileCount: record.files.count,
            inputFileNames: record.files.map { $0.source.lastPathComponent }, status: record.state.title,
            inputSize: results.reduce(0) { $0 + $1.originalSize }, outputSize: results.reduce(0) { $0 + $1.convertedSize }, descriptionText: record.summary)
    }
    func cancelProcessing() { if let taskID { taskManager.cancel(taskID) } }
    func retryFailed() { if let taskID { taskManager.retry(taskID) } }
    func saveResults() {
        guard !isProcessing, !isSaving, !results.isEmpty else { return }
        let urls = results.map(\.convertedURL)
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
