import Foundation
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
#if canImport(Translation)
import Translation
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 工具枚举

enum MediaConversionTool: String, CaseIterable {
    case speechToText = "语音转字幕"
    case gifGeneration = "GIF 生成"
}

// MARK: - 结果项

struct MediaConversionResultItem: Identifiable {
    let id = UUID()
    let originalURL: URL
    let outputURL: URL
    let originalSize: Int64
    let outputSize: Int64
    let tool: MediaConversionTool
    let operationDescription: String
    var subtitleEntries: [SubtitleEntry]?
    var fullText: String?
    var translatedFullText: String?
    var detectedLanguage: String?
    var audioDuration: TimeInterval?
    var gifFrameCount: Int?

    var savedPercent: String {
        guard originalSize > 0 else { return "0" }
        let saved = Double(originalSize - outputSize) / Double(originalSize) * 100
        return String(format: "%.0f", max(0, saved))
    }
}

// MARK: - 音视频转换 ViewModel

@Observable
final class MediaConversionViewModel: @unchecked Sendable {

    // MARK: 工具选择

    var selectedTool: MediaConversionTool = .speechToText

    // MARK: 文件选择

    var selectedFiles: [URL] = []
    var originalSizes: [URL: Int64] = [:]

    // MARK: 语音转字幕参数

    var sourceLanguage: String = "zh-CN"
    var subtitleFormat: SubtitleExportFormat = .plainText
    var showBilingualOption: Bool = false
    var targetLanguage: String = "en-US"

    // MARK: GIF 生成参数

    var gifFrameRate: Int = 10
    var gifMaxSize: CGFloat = 480
    var gifStartTime: TimeInterval = 0
    var gifDuration: TimeInterval = 5
    var currentVideoDuration: TimeInterval = 0

    // MARK: 处理状态

    var isProcessing = false { didSet { ProcessingActivity.setActive(isProcessing, owner: ObjectIdentifier(self)) } }
    var progress: Double = 0
    var currentFileName: String = ""
    var cancelled = false

    // MARK: 结果

    var results: [MediaConversionResultItem] = []
    var successMessage: String?
    var errorMessage: String?

    // MARK: 翻译桥接（由 View 的 .translationTask() 注入）

    private var _translationSession: Any? = nil
    private var _translationSessionContinuation: CheckedContinuation<Void, Never>? = nil
    private var _translationContinuationResumed = false

    @available(macOS 15.0, *)
    private var translationSession: TranslationSession? {
        get { _translationSession as? TranslationSession }
        set { _translationSession = newValue }
    }

    /// 由 View 的 .translationTask() 调用，注入 TranslationSession
    @available(macOS 15.0, *)
    func setTranslationSession(_ session: TranslationSession) {
        translationSession = session
        guard !_translationContinuationResumed else { return }
        _translationContinuationResumed = true
        _translationSessionContinuation?.resume()
        _translationSessionContinuation = nil
    }

    /// 等待 TranslationSession 就绪（若已就绪则立即返回）
    @available(macOS 15.0, *)
    private func waitForTranslationSession() async {
        if translationSession != nil { return }
        _translationContinuationResumed = false
        // 5秒超时保护，防止永久挂起
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self._translationContinuationResumed else { return }
            self._translationContinuationResumed = true
            self._translationSessionContinuation?.resume()
            self._translationSessionContinuation = nil
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if _translationContinuationResumed {
                // 超时已先触发，立即恢复
                c.resume()
            } else {
                _translationSessionContinuation = c
            }
        }
    }

    // MARK: 服务

    private var speechService = SpeechToTextService()
    private let gifService = GIFGenerationService()

    // MARK: 取消控制

    /// 当前正在执行的后台任务（允许外部取消）
    private var currentTask: Task<Void, Never>?

    /// 最后一次进度更新的时间（用于检测卡死）
    private var lastProgressTime: Date = .distantPast
    private var stuckCheckTimer: Timer?

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
        case .speechToText:
            return true
        case .gifGeneration:
            return gifDuration > 0
        }
    }

    var allowedContentTypes: [UTType] {
        switch selectedTool {
        case .speechToText:
            return SpeechToTextService.supportedFormats
        case .gifGeneration:
            return GIFGenerationService.supportedFormats
        }
    }

    var supportedLanguages: [(code: String, name: String)] {
        SpeechToTextService.supportedLanguages
    }

    /// 是否有字幕编辑结果
    var hasTranscribedResults: Bool {
        results.contains { $0.subtitleEntries != nil || $0.fullText != nil }
    }

    // MARK: 文件选择

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

        // 更新当前文件的时长信息
        updateDurations()
        clearMessages()
    }

    func removeFile(url: URL) {
        guard !isProcessing else { return }
        guard let index = selectedFiles.firstIndex(of: url) else { return }
        selectedFiles.remove(at: index)
        originalSizes.removeValue(forKey: url)
        results.removeAll { $0.originalURL == url }
        updateDurations()
    }

    private func updateDurations() {
        if let first = selectedFiles.first {
            let asset = AVURLAsset(url: first)
            let dur = CMTimeGetSeconds(asset.duration)
            currentVideoDuration = dur
            if gifDuration > dur {
                gifDuration = min(5, dur)
            }
        }
    }

    // MARK: 字幕编辑

    func updateSubtitleEntry(resultID: UUID, entryIndex: Int, text: String) {
        guard let idx = results.firstIndex(where: { $0.id == resultID }),
              var entries = results[idx].subtitleEntries,
              entryIndex < entries.count else { return }
        entries[entryIndex].text = text
        results[idx].subtitleEntries = entries
    }

    func updateTranslatedText(resultID: UUID, entryIndex: Int, text: String) {
        guard let idx = results.firstIndex(where: { $0.id == resultID }),
              var entries = results[idx].subtitleEntries,
              entryIndex < entries.count else { return }
        entries[entryIndex].translatedText = text.isEmpty ? nil : text
        results[idx].subtitleEntries = entries
    }

    // MARK: 保存结果

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

    /// 重新导出字幕（编辑后）
    @MainActor
    func reExportSubtitles(resultID: UUID) {
        guard let idx = results.firstIndex(where: { $0.id == resultID }) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = {
            switch subtitleFormat {
            case .srt: return [UTType(filenameExtension: "srt") ?? .plainText]
            case .vtt: return [UTType(filenameExtension: "vtt") ?? .plainText]
            case .txt, .plainText: return [.plainText]
            }
        }()
        let ext = subtitleFormat == .plainText ? "txt" : subtitleFormat.rawValue.lowercased()
        panel.nameFieldStringValue = "字幕.\(ext)"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                switch subtitleFormat {
                case .srt:
                    if let entries = results[idx].subtitleEntries {
                        try speechService.exportSRT(entries, outputURL: url)
                    }
                case .vtt:
                    if let entries = results[idx].subtitleEntries {
                        try speechService.exportVTT(entries, outputURL: url)
                    }
                case .txt:
                    if let entries = results[idx].subtitleEntries {
                        try speechService.exportTXT(entries, outputURL: url)
                    }
                case .plainText:
                    if let tft = results[idx].translatedFullText, !tft.isEmpty,
                       let fullText = results[idx].fullText {
                        try speechService.exportPlainTextBilingual(
                            fullText: fullText,
                            translatedFullText: tft,
                            outputURL: url
                        )
                    } else if let fullText = results[idx].fullText {
                        try speechService.exportPlainText(fullText, outputURL: url)
                    }
                }
                successMessage = "字幕已导出到 \(url.lastPathComponent)"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: 执行

    func execute() {
        guard canExecute else { return }

        cancelCurrentTask()
        isProcessing = true
        cancelled = false
        progress = 0
        results = []
        lastProgressTime = Date()
        clearMessages()
        startStuckDetection()

        switch selectedTool {
        case .speechToText:
            executeSpeechToText()
        case .gifGeneration:
            executeGIFGeneration()
        }
    }

    /// 取消当前任务：终止后台运算 + 销毁线程 + 清理缓存 + 重置 UI
    func cancelOperation() {
        cancelled = true
        speechService.cancelRecognition()
        currentTask?.cancel()
        currentTask = nil
        stopStuckDetection()

        Task { @MainActor in
            self.isProcessing = false
            self.progress = 0
            self.currentFileName = ""
            self.errorMessage = "已取消本次处理"
        }
    }

    private func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
        stopStuckDetection()
    }

    // MARK: 卡死检测（20 秒无进度 → 自动终止）

    private func startStuckDetection() {
        lastProgressTime = Date()
        stuckCheckTimer?.invalidate()
        stuckCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.isProcessing else { return }
            let elapsed = Date().timeIntervalSince(self.lastProgressTime)
            if elapsed > 20 {
                Task { @MainActor in
                    self.errorMessage = "处理超时（20秒无响应），已自动终止，请重试"
                    self.cancelOperation()
                }
            }
        }
    }

    private func stopStuckDetection() {
        stuckCheckTimer?.invalidate()
        stuckCheckTimer = nil
    }

    @MainActor
    private func updateProgress(_ value: Double, fileName: String) {
        progress = value
        currentFileName = fileName
        lastProgressTime = Date()
    }

    private func clearMessages() {
        successMessage = nil
        errorMessage = nil
    }

    // MARK: 语音转文字

    private func executeSpeechToText() {
        let files = selectedFiles
        let lang = sourceLanguage
        let fmt = subtitleFormat
        let showBilingual = showBilingualOption

        currentTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            var items: [MediaConversionResultItem] = []
            var errors: [String] = []
            var wasCancelled = false

            // 安全网：任何未捕获异常都保证 UI 恢复，杜绝按钮假死
            defer {
                self.stopStuckDetection()
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.isProcessing {
                        self.isProcessing = false
                        self.currentTask = nil
                        if self.errorMessage == nil {
                            self.errorMessage = "处理意外终止，请重试"
                        }
                    }
                }
            }

            for (i, url) in files.enumerated() {
                // 多点协作取消检查
                if self.cancelled || Task.isCancelled { wasCancelled = true; break }
                try? Task.checkCancellation()

                let name = url.lastPathComponent
                await self.updateProgress(Double(i) / Double(files.count), fileName: name)

                do {
                    var result = try await self.speechService.transcribe(
                        url: url,
                        language: lang
                    ) { prog, status in
                        let overall = (Double(i) + prog) / Double(files.count)
                        Task { @MainActor in
                            self.progress = overall
                            self.currentFileName = "\(name) — \(status)"
                            self.lastProgressTime = Date()
                        }
                    }

                    // 检查是否在转写过程中被取消
                    if self.cancelled || Task.isCancelled { wasCancelled = true; break }

                    // 双语翻译（macOS 15.0+ 本地离线翻译）
                    var translatedFullText: String?
                    if showBilingual {
                        if #available(macOS 15.0, *) {
                            await self.waitForTranslationSession()
                            if let session = self.translationSession {
                                let translatedEntries = try await self.speechService.translateSubtitles(
                                    result.entries,
                                    using: session
                                )
                                result = TranscriptionResult(
                                    entries: translatedEntries,
                                    fullText: result.fullText,
                                    detectedLanguage: result.detectedLanguage,
                                    confidence: result.confidence
                                )
                                translatedFullText = self.speechService.translatedFullText(from: translatedEntries)
                            }
                        }
                    }

                    // 导出字幕到临时文件
                    let baseName = (name as NSString).deletingPathExtension
                    let ext = fmt == .plainText ? "txt" : fmt.rawValue.lowercased()
                    let outputURL = CacheManager.isolatedDirectory(in: CacheManager.mediaCacheDirectory)
                        .appendingPathComponent("\(baseName)_字幕.\(ext)")
                    try? FileManager.default.removeItem(at: outputURL)

                    switch fmt {
                    case .srt: try self.speechService.exportSRT(result.entries, outputURL: outputURL)
                    case .vtt: try self.speechService.exportVTT(result.entries, outputURL: outputURL)
                    case .txt: try self.speechService.exportTXT(result.entries, outputURL: outputURL)
                    case .plainText:
                        if let tft = translatedFullText, !tft.isEmpty {
                            try self.speechService.exportPlainTextBilingual(
                                fullText: result.fullText,
                                translatedFullText: tft,
                                outputURL: outputURL
                            )
                        } else {
                            try self.speechService.exportPlainText(result.fullText, outputURL: outputURL)
                        }
                    }

                    let originalSize = FileUtils.fileSize(of: url)
                    let outSize = FileUtils.fileSize(of: outputURL)

                    items.append(MediaConversionResultItem(
                        originalURL: url,
                        outputURL: outputURL,
                        originalSize: originalSize,
                        outputSize: outSize,
                        tool: .speechToText,
                        operationDescription: "语音转字幕",
                        subtitleEntries: result.entries,
                        fullText: result.fullText,
                        translatedFullText: translatedFullText,
                        detectedLanguage: result.detectedLanguage
                    ))
                } catch let sttError as SpeechToTextError {
                    // 区分取消（用户主动/超时）和真正的处理错误
                    switch sttError {
                    case .cancelled:
                        // 用户手动取消 或 超时自动取消 → 终止全部处理
                        wasCancelled = true
                    case .preprocessingFailed:
                        // 预处理失败 ≠ 取消，记录错误并继续处理下一个文件
                        errors.append("\(name): \(sttError.localizedDescription)")
                    default:
                        // 其他识别错误（无语音、识别器不可用等）
                        errors.append("\(name): \(sttError.localizedDescription)")
                    }
                    if wasCancelled { break }
                } catch {
                    // 区分 NSURLErrorCancelled 和真正的错误
                    let nsErr = error as NSError
                    if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                        wasCancelled = true; break
                    }
                    errors.append("\(name): \(error.localizedDescription)")
                }

                await self.updateProgress(Double(i + 1) / Double(files.count), fileName: "")
            }

            // 最终 UI 更新
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.currentTask = nil

                if wasCancelled {
                    self.progress = 0
                    self.currentFileName = ""
                    if self.errorMessage == nil {
                        self.errorMessage = "已取消本次处理"
                    }
                    return
                }

                self.progress = 1.0
                self.results = items

                if errors.isEmpty {
                    self.successMessage = "成功转录 \(items.count) 个文件"
                } else if items.isEmpty {
                    // 全部失败：显示错误而非成功
                    self.errorMessage = errors.joined(separator: "\n")
                } else {
                    self.successMessage = "成功 \(items.count) 个，\(errors.count) 个失败"
                }

                if !items.isEmpty {
                    HistoryService().addRecord(
                        toolName: "音视频转换",
                        operationType: "语音转字幕",
                        fileCount: files.count,
                        inputFileNames: files.map { $0.lastPathComponent },
                        status: errors.isEmpty ? "成功" : "部分成功",
                        inputSize: items.reduce(0) { $0 + $1.originalSize },
                        outputSize: items.reduce(0) { $0 + $1.outputSize },
                        descriptionText: "将 \(files.count) 个音频文件转录为字幕"
                    )
                }
            }
        }
    }

    // MARK: GIF 生成

    private func executeGIFGeneration() {
        let files = selectedFiles
        let fps = gifFrameRate
        let maxSize = gifMaxSize
        let start = gifStartTime
        let duration = gifDuration

        // 分离视频文件和 GIF 文件
        let videoFiles = files.filter { $0.pathExtension.lowercased() != "gif" }
        let gifFiles = files.filter { $0.pathExtension.lowercased() == "gif" }

        currentTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var items: [MediaConversionResultItem] = []
            var errors: [String] = []

            // 安全网：任何未捕获异常都保证 UI 恢复
            defer {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.isProcessing {
                        self.isProcessing = false
                        self.progress = 0
                        if self.errorMessage == nil {
                            self.errorMessage = "处理意外终止，请重试"
                        }
                    }
                }
            }

            // 处理视频文件 → 生成 GIF
            for (i, url) in videoFiles.enumerated() {
                guard !self.cancelled else { break }

                let name = url.lastPathComponent
                await MainActor.run { self.currentFileName = name }

                let baseName = (name as NSString).deletingPathExtension
                let outputURL = CacheManager.isolatedDirectory(in: CacheManager.mediaCacheDirectory)
                    .appendingPathComponent("\(baseName).gif")

                do {
                    let result = try self.gifService.generateGIF(
                        from: url,
                        frameRate: fps,
                        maxDimension: maxSize,
                        startTime: start,
                        duration: duration,
                        outputURL: outputURL
                    ) { prog, status in
                        Task { @MainActor in
                            let fileProgress = Double(videoFiles.count) > 0
                                ? (Double(i) + prog) / Double(files.count)
                                : 0
                            self.progress = fileProgress
                            self.currentFileName = "\(name) — \(status)"
                        }
                    }

                    items.append(MediaConversionResultItem(
                        originalURL: url,
                        outputURL: outputURL,
                        originalSize: result.originalSize,
                        outputSize: result.gifSize,
                        tool: .gifGeneration,
                        operationDescription: "视频转 GIF (\(result.frameCount)帧)",
                        gifFrameCount: result.frameCount
                    ))
                } catch {
                    errors.append("\(name): \(error.localizedDescription)")
                }

                let prog = Double(i + 1) / Double(files.count)
                await MainActor.run { self.progress = prog }
            }

            // 处理 GIF 文件 → 压缩
            for (i, url) in gifFiles.enumerated() {
                guard !self.cancelled else { break }

                let name = url.lastPathComponent
                await MainActor.run { self.currentFileName = name }

                let baseName = (name as NSString).deletingPathExtension
                let outputURL = CacheManager.isolatedDirectory(in: CacheManager.mediaCacheDirectory)
                    .appendingPathComponent("\(baseName)_压缩.gif")

                do {
                    let result = try self.gifService.compressGIF(
                        url: url,
                        maxDimension: maxSize,
                        frameSkip: max(1, 20 / fps),
                        outputURL: outputURL
                    ) { prog, status in
                        Task { @MainActor in
                            let fileProgress = (Double(videoFiles.count + i) + prog) / Double(files.count)
                            self.progress = fileProgress
                            self.currentFileName = "\(name) — \(status)"
                        }
                    }

                    items.append(MediaConversionResultItem(
                        originalURL: url,
                        outputURL: outputURL,
                        originalSize: result.originalSize,
                        outputSize: result.gifSize,
                        tool: .gifGeneration,
                        operationDescription: "GIF 压缩 (\(result.frameCount)帧)",
                        gifFrameCount: result.frameCount
                    ))
                } catch {
                    errors.append("\(name): \(error.localizedDescription)")
                }

                let prog = Double(videoFiles.count + i + 1) / Double(files.count)
                await MainActor.run { self.progress = prog }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isProcessing = false
                self.progress = 1.0
                self.results = items
                self.errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
                if errors.isEmpty {
                    self.successMessage = "成功处理 \(items.count) 个文件"
                } else {
                    self.successMessage = "成功 \(items.count) 个，\(errors.count) 个失败"
                }
                if !items.isEmpty {
                    let opType = items.first?.operationDescription ?? "GIF处理"
                    HistoryService().addRecord(
                        toolName: "音视频转换",
                        operationType: opType,
                        fileCount: files.count,
                        inputFileNames: files.map { $0.lastPathComponent },
                        status: errors.isEmpty ? "成功" : "部分成功",
                        inputSize: items.reduce(0) { $0 + $1.originalSize },
                        outputSize: items.reduce(0) { $0 + $1.outputSize },
                        descriptionText: "\(opType) — 共 \(items.count) 个文件"
                    )
                }
            }
        }
    }
}
