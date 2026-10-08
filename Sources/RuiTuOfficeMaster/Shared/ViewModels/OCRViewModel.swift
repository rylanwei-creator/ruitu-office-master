import Foundation
import SwiftUI
import AppKit
import NaturalLanguage
import UniformTypeIdentifiers

#if canImport(Translation)
import Translation
#endif

// MARK: - 导入模式

enum OCRImportMode: String, CaseIterable {
    case singleImage = "单张图片"
    case batchImages = "多张图片"
    case pdf = "PDF 文档"
}

// MARK: - OCR ViewModel

@Observable
final class OCRViewModel: @unchecked Sendable {

    // MARK: 导入模式

    var importMode: OCRImportMode = .singleImage

    // MARK: 图片选择（单张 / 批量）

    /// 当前选中的图片（单张模式）
    var selectedImage: URL?
    /// 批量选中的图片
    var selectedImages: [URL] = []
    /// 选中的 PDF 文件
    var selectedPDF: URL?
    /// 文件大小缓存
    var fileSizes: [URL: Int64] = [:]

    // MARK: 识别参数

    /// 识别语言列表
    var selectedLanguages: [String] = [OCRService.autoDetectIdentifier]
    /// 是否启用图片预处理增强（提亮、加对比度）
    var enablePreprocess: Bool = true

    // MARK: 处理状态

    var isProcessing = false { didSet { ProcessingActivity.setActive(isProcessing, owner: ObjectIdentifier(self)) } }
    var progress: Double = 0
    var currentFileName = ""
    /// 批量/PDF 的当前进度描述
    var progressDetail = ""

    // MARK: 识别结果

    var recognizedText: String = ""
    var errorMessage: String?
    var successMessage: String?

    var hasResult: Bool { !recognizedText.isEmpty }

    // MARK: 翻译（macOS 15.0+，通过 View 的 .translationTask() 桥接）

    var translatedText: String = ""
    var isTranslating = false

    var hasTranslation: Bool { !translatedText.isEmpty }

    // 桥接：避免直接引用 TranslationSession 类型
    private var _translationSession: Any? = nil
    private var _translationContinuation: CheckedContinuation<Void, Never>? = nil
    private var _translationContinuationResumed = false
    private var _pendingTranslation = false

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
        _translationContinuation?.resume()
        _translationContinuation = nil
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
            self._translationContinuation?.resume()
            self._translationContinuation = nil
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            if _translationContinuationResumed {
                // 超时已先触发，立即恢复
                c.resume()
            } else {
                _translationContinuation = c
            }
        }
    }

    // MARK: 图片预览

    var previewImage: Image? {
        switch importMode {
        case .singleImage:
            guard let url = selectedImage else { return nil }
            if let nsImage = NSImage(contentsOf: url) {
                return Image(nsImage: nsImage)
            }
            return nil
        case .batchImages, .pdf:
            return nil
        }
    }

    // MARK: 计算属性

    var canExecute: Bool {
        guard !isProcessing else { return false }
        switch importMode {
        case .singleImage:
            return selectedImage != nil
        case .batchImages:
            return !selectedImages.isEmpty
        case .pdf:
            return selectedPDF != nil
        }
    }

    var fileCountText: String {
        switch importMode {
        case .singleImage:
            return selectedImage != nil ? "已选择 1 个文件" : ""
        case .batchImages:
            return selectedImages.isEmpty ? "" : "已选择 \(selectedImages.count) 张图片"
        case .pdf:
            return selectedPDF != nil ? "已选择 1 个 PDF" : ""
        }
    }

    var totalSizeText: String {
        let urls: [URL]
        switch importMode {
        case .singleImage:
            urls = selectedImage.map { [$0] } ?? []
        case .batchImages:
            urls = selectedImages
        case .pdf:
            urls = selectedPDF.map { [$0] } ?? []
        }
        let total = urls.reduce(0) { $0 + (fileSizes[$1] ?? 0) }
        return FileUtils.formatSize(total)
    }

    // MARK: 切换导入模式

    func switchImportMode(to mode: OCRImportMode) {
        guard !isProcessing, mode != importMode else { return }
        importMode = mode
        clearAll()
    }

    // MARK: 文件选择

#if os(macOS)
    @MainActor
    func selectFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = OCRService.allSupportedFormats

        switch importMode {
        case .singleImage:
            panel.allowsMultipleSelection = false
            panel.title = "选择图片"
        case .batchImages:
            panel.allowsMultipleSelection = true
            panel.title = "选择多张图片"
        case .pdf:
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.pdf]
            panel.title = "选择 PDF 文档"
        }

        if panel.runModal() == .OK {
            switch importMode {
            case .singleImage:
                if let url = panel.urls.first { setSingleImage(url) }
            case .batchImages:
                addImages(from: panel.urls)
            case .pdf:
                if let url = panel.urls.first { setPDF(url) }
            }
        }
    }
#endif

    /// 拖拽导入
    func addFile(from url: URL) {
        guard !isProcessing, url.isFileURL else { return }
        guard let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
              let type = UTType(uti) else { return }

        if type.conforms(to: .pdf) {
            importMode = .pdf
            setPDF(url)
        } else if OCRService.supportedFormats.contains { type.conforms(to: $0) } {
            switch importMode {
            case .singleImage:
                setSingleImage(url)
            case .batchImages:
                addImages(from: [url])
            case .pdf:
                // PDF 模式下拖入图片，自动切换到单张模式
                importMode = .singleImage
                setSingleImage(url)
            }
        }
    }

    private func setSingleImage(_ url: URL) {
        selectedImage = url
        selectedImages = []
        selectedPDF = nil
        fileSizes = [url: FileUtils.fileSize(of: url)]
        recognizedText = ""
        translatedText = ""
        clearMessages()
    }

    private func addImages(from urls: [URL]) {
        guard !isProcessing else { return }
        let valid = urls.filter { url in
            guard url.isFileURL, !selectedImages.contains(url) else { return false }
            guard let uti = (try? url.resourceValues(forKeys: [.typeIdentifierKey]))?.typeIdentifier,
                  let type = UTType(uti) else { return false }
            return OCRService.supportedFormats.contains { type.conforms(to: $0) }
        }
        selectedImages.append(contentsOf: valid)
        for url in valid {
            fileSizes[url] = FileUtils.fileSize(of: url)
        }
        selectedImage = nil
        selectedPDF = nil
        recognizedText = ""
        translatedText = ""
        clearMessages()
    }

    private func setPDF(_ url: URL) {
        selectedPDF = url
        selectedImage = nil
        selectedImages = []
        fileSizes = [url: FileUtils.fileSize(of: url)]
        recognizedText = ""
        translatedText = ""
        clearMessages()
    }

    /// 移除某个文件（批量模式）
    func removeFile(url: URL) {
        guard !isProcessing else { return }
        selectedImages.removeAll { $0 == url }
        fileSizes.removeValue(forKey: url)
    }

    /// 清空所有文件和结果
    func clearAll() {
        guard !isProcessing else { return }
        selectedImage = nil
        selectedImages = []
        selectedPDF = nil
        fileSizes = [:]
        recognizedText = ""
        translatedText = ""
        clearMessages()
    }

    // MARK: 执行识别

    func executeRecognition() {
        guard canExecute else { return }

        isProcessing = true
        progress = 0
        currentFileName = ""
        progressDetail = ""
        errorMessage = nil
        successMessage = nil
        translatedText = ""

        let languages = selectedLanguages
        let preprocess = enablePreprocess
        let service = OCRService()

        switch importMode {
        case .singleImage:
            executeSingleImage(languages: languages, preprocess: preprocess, service: service)
        case .batchImages:
            executeBatch(languages: languages, preprocess: preprocess, service: service)
        case .pdf:
            executePDF(languages: languages, preprocess: preprocess, service: service)
        }
    }

    private func executeSingleImage(languages: [String], preprocess: Bool, service: OCRService) {
        guard let url = selectedImage else { return }

        Task(priority: .userInitiated) {
            do {
                await updateProgress(0.3, fileName: url.lastPathComponent, detail: "预处理中...")
                let cgImage = try service.loadImage(from: url)

                await updateProgress(0.6, fileName: url.lastPathComponent, detail: "识别中...")

                let text = try await service.recognizeText(
                    from: cgImage,
                    languages: languages,
                    preprocess: preprocess
                )

                await MainActor.run {
                    self.recognizedText = text
                    self.progress = 1.0
                    self.isProcessing = false
                    self.successMessage = "识别完成，共 \(text.components(separatedBy: "\n").count) 行文字"
                    HistoryService().addRecord(
                        toolName: "OCR 文字识别",
                        operationType: "单张图片识别",
                        fileCount: 1,
                        inputFileNames: [url.lastPathComponent],
                        status: "成功",
                        inputSize: fileSizes[url] ?? 0,
                        outputSize: 0,
                        descriptionText: "识别单张图片，共 \(text.components(separatedBy: "\n").count) 行文字"
                    )
                }
            } catch {
                await handleError(error)
            }
        }
    }

    private func executeBatch(languages: [String], preprocess: Bool, service: OCRService) {
        let urls = selectedImages

        Task(priority: .userInitiated) {
            do {
                let text = try await service.recognizeBatch(
                    urls: urls,
                    languages: languages,
                    preprocess: preprocess
                ) { [weak self] current, total in
                    Task { @MainActor [weak self] in
                        self?.progress = Double(current) / Double(total)
                        self?.currentFileName = urls[safe: current - 1]?.lastPathComponent ?? ""
                        self?.progressDetail = "\(current) / \(total)"
                    }
                }

                await MainActor.run {
                    self.recognizedText = text
                    self.progress = 1.0
                    self.isProcessing = false
                    self.successMessage = "批量识别完成，共处理 \(urls.count) 张图片"
                    HistoryService().addRecord(
                        toolName: "OCR 文字识别",
                        operationType: "批量图片识别",
                        fileCount: urls.count,
                        inputFileNames: urls.map { $0.lastPathComponent },
                        status: "成功",
                        inputSize: urls.reduce(0) { $0 + (fileSizes[$1] ?? 0) },
                        outputSize: 0,
                        descriptionText: "批量识别 \(urls.count) 张图片"
                    )
                }
            } catch {
                await handleError(error)
            }
        }
    }

    private func executePDF(languages: [String], preprocess: Bool, service: OCRService) {
        guard let url = selectedPDF else { return }

        Task(priority: .userInitiated) {
            do {
                let text = try await service.recognizePDF(
                    url: url,
                    languages: languages,
                    preprocess: preprocess
                ) { [weak self] current, total in
                    Task { @MainActor [weak self] in
                        self?.progress = Double(current) / Double(total)
                        self?.currentFileName = "第 \(current) 页"
                        self?.progressDetail = "\(current) / \(total) 页"
                    }
                }

                await MainActor.run {
                    self.recognizedText = text
                    self.progress = 1.0
                    self.isProcessing = false
                    self.successMessage = "PDF 识别完成"
                    HistoryService().addRecord(
                        toolName: "OCR 文字识别",
                        operationType: "PDF 识别",
                        fileCount: 1,
                        inputFileNames: [url.lastPathComponent],
                        status: "成功",
                        inputSize: fileSizes[url] ?? 0,
                        outputSize: 0,
                        descriptionText: "从 PDF 文档中提取文字"
                    )
                }
            } catch {
                await handleError(error)
            }
        }
    }

    @MainActor
    private func updateProgress(_ prog: Double, fileName: String, detail: String) {
        progress = prog
        currentFileName = fileName
        progressDetail = detail
    }

    @MainActor
    private func handleError(_ error: Error) {
        isProcessing = false
        progress = 0
        errorMessage = error.localizedDescription
    }

    // MARK: 结果操作

    /// 一键规整排版
    func reformatText() {
        guard hasResult else { return }
        recognizedText = OCRService.reformatText(recognizedText)
        successMessage = "排版规整完成"
    }

    /// 一键复制
    func copyAllText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recognizedText, forType: .string)
        successMessage = "已复制到剪贴板"
    }

    /// 保存为 TXT
#if os(macOS)
    @MainActor
    func saveAsText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "OCR识别结果.txt"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try recognizedText.write(to: url, atomically: true, encoding: .utf8)
                successMessage = "已保存为 TXT 文件"
            } catch {
                errorMessage = "保存失败: \(error.localizedDescription)"
            }
        }
    }
#endif

    /// 导出为 Word 兼容格式（RTF）
    #if os(macOS)
    @MainActor
    func exportAsWord() {
        guard hasResult else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf]
        panel.nameFieldStringValue = "OCR识别结果.rtf"
        panel.title = "导出为 Word 兼容文档"

        if panel.runModal() == .OK, let url = panel.url {
            guard let rtfData = OCRService.exportAsRTF(recognizedText) else {
                errorMessage = "生成文档失败"
                return
            }
            do {
                try rtfData.write(to: url)
                successMessage = "已导出为 Word 兼容文档（RTF 格式）"
            } catch {
                errorMessage = "导出失败: \(error.localizedDescription)"
            }
        }
    }
    #endif

    /// 触发翻译（通过 View 的 .translationTask() 桥接，macOS 15.0+）
    @MainActor
    func triggerTranslation() {
        guard hasResult, !isTranslating else { return }
        isTranslating = true
        _pendingTranslation = true
        if #available(macOS 15.0, *) {
            Task { await performTranslation() }
        } else {
            isTranslating = false
            errorMessage = "翻译功能需要 macOS 15.0 或更高版本"
        }
    }

    /// 执行翻译（异步等待 TranslationSession 就绪后调用）
    @available(macOS 15.0, *)
    private func performTranslation() async {
        guard _pendingTranslation else { return }
        await waitForTranslationSession()
        guard let session = translationSession, _pendingTranslation else {
            await MainActor.run { isTranslating = false }
            return
        }

        _pendingTranslation = false

        // 检测源语言
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(recognizedText)
        let dominantLang = recognizer.dominantLanguage

        let requests: [TranslationSession.Request]
        if let lang = dominantLang {
            let source = Locale.Language(identifier: lang.rawValue)
            requests = [TranslationSession.Request(sourceText: recognizedText,
                                                     clientIdentifier: "ocr-\(source.maximalIdentifier)")]
        } else {
            requests = [TranslationSession.Request(sourceText: recognizedText,
                                                     clientIdentifier: "ocr-auto")]
        }

        do {
            let response = try await session.translations(from: requests)
            if let first = response.first {
                await MainActor.run {
                    translatedText = first.targetText
                    isTranslating = false
                    successMessage = "翻译完成"
                }
            } else {
                await MainActor.run {
                    isTranslating = false
                    errorMessage = "翻译失败，请重试"
                }
            }
        } catch {
            await MainActor.run {
                isTranslating = false
                errorMessage = "翻译失败: \(error.localizedDescription)"
            }
        }
    }

    // MARK: 工具

    private func clearMessages() {
        errorMessage = nil
        successMessage = nil
    }
}

// MARK: - 安全数组访问

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
