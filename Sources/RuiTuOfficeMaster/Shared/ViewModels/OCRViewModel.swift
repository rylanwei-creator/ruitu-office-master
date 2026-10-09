import Foundation
import SwiftUI
import AppKit
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

    var recognizedText: String = "" {
        didSet {
            if oldValue != recognizedText {
                invalidateTranslation()
                translatedText = ""
            }
        }
    }
    var imageResults: [OCRImageResult] = []
    var isExportingTexts = false
    var errorMessage: String?
    var successMessage: String?

    var hasResult: Bool { !imageResults.isEmpty || !recognizedText.isEmpty }
    var hasText: Bool { imageResults.isEmpty ? !recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : imageResults.contains(where: \.hasText) }
    var allResultText: String { imageResults.isEmpty ? recognizedText : OCRImageResult.combinedText(imageResults) }

    // MARK: 翻译（macOS 15.0+，通过 View 的 .translationTask() 桥接）

    var translatedText: String = ""
    var isTranslating = false

    var hasTranslation: Bool { !translatedText.isEmpty }

    // 桥接：避免直接引用 TranslationSession 类型
    private var _translationSession: Any? = nil
    private var translationRevision = UUID()
    private var translationTask: Task<Void, Never>?

    @available(macOS 15.0, *)
    private var translationSession: TranslationSession? {
        get { _translationSession as? TranslationSession }
        set { _translationSession = newValue }
    }

    /// 由 View 的 .translationTask() 调用，注入 TranslationSession
    @available(macOS 15.0, *)
    @MainActor
    func setTranslationSession(_ session: TranslationSession) {
        translationSession = session
    }

    /// 等待 View 注入服务，取消或切换文件时及时退出。
    @available(macOS 15.0, *)
    @MainActor
    private func waitForTranslationSession() async {
        for _ in 0..<20 {
            if translationSession != nil || Task.isCancelled { return }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
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

        let mode = importMode
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            guard let self, !self.isProcessing, self.importMode == mode else { return }
            switch mode {
            case .singleImage:
                if let url = urls.first { self.setSingleImage(url) }
            case .batchImages:
                self.addImages(from: urls)
            case .pdf:
                if let url = urls.first { self.setPDF(url) }
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
        } else if OCRService.supportedFormats.contains(where: { type.conforms(to: $0) }) {
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
        resetResults()
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
        resetResults()
        clearMessages()
    }

    private func setPDF(_ url: URL) {
        selectedPDF = url
        selectedImage = nil
        selectedImages = []
        fileSizes = [url: FileUtils.fileSize(of: url)]
        resetResults()
        clearMessages()
    }

    /// 移除某个文件（批量模式）
    func removeFile(url: URL) {
        guard !isProcessing else { return }
        selectedImages.removeAll { $0 == url }
        fileSizes.removeValue(forKey: url)
        resetResults()
        clearMessages()
    }

    /// 清空所有文件和结果
    func clearAll() {
        guard !isProcessing else { return }
        selectedImage = nil
        selectedImages = []
        selectedPDF = nil
        fileSizes = [:]
        resetResults()
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
        resetResults()

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
                let results = try await service.recognizeBatchResults(
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
                    self.imageResults = results
                    self.progress = 1.0
                    self.isProcessing = false
                    let recognized = results.filter { $0.status == .recognized }.count
                    let blank = results.filter { $0.status == .noText }.count
                    let failed = results.count - recognized - blank
                    self.successMessage = "识别完成：\(recognized) 张有文字，\(blank) 张无文字，\(failed) 张失败"
                    HistoryService().addRecord(
                        toolName: "OCR 文字识别",
                        operationType: "批量图片识别",
                        fileCount: urls.count,
                        inputFileNames: urls.map { $0.lastPathComponent },
                        status: failed == 0 ? "成功" : (failed == urls.count ? "失败" : "部分成功"),
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

    func setImageText(id: UUID, text: String) {
        guard let index = imageResults.firstIndex(where: { $0.id == id }), imageResults[index].text != text else { return }
        invalidateTranslation()
        imageResults[index].text = text
        imageResults[index].translatedText = ""
    }

    func setImageTranslation(id: UUID, text: String) {
        guard let index = imageResults.firstIndex(where: { $0.id == id }) else { return }
        imageResults[index].translatedText = text
    }

    /// 每张图片独立排版，避免跨图片合并段落。
    func reformatText() {
        guard hasText else { return }
        if imageResults.isEmpty {
            recognizedText = OCRService.reformatText(recognizedText)
        } else {
            for result in imageResults {
                setImageText(id: result.id, text: OCRService.reformatText(result.text))
            }
        }
        successMessage = "排版规整完成"
    }

    func copyAllText() { copyText(allResultText) }

    func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        successMessage = "已复制到剪贴板"
    }

#if os(macOS)
    @MainActor
    func saveAsText(resultID: UUID? = nil) {
        let result = resultID.flatMap { id in imageResults.first(where: { $0.id == id }) }
        let text = result?.text ?? allResultText
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = result.map { $0.sourceURL.deletingPathExtension().lastPathComponent + "_识别结果.txt" } ?? "OCR识别结果.txt"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.successMessage = "已保存为 TXT 文件"
            } catch { self.errorMessage = "保存失败: \(error.localizedDescription)" }
        }
    }

    @MainActor
    func saveSeparateTexts() {
        guard !isExportingTexts, imageResults.contains(where: \.hasText) else { return }
        let snapshot = imageResults
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "保存到这里"
        panel.title = "分别导出图片识别文字"
        panel.message = "每张图片生成一个 TXT，保留图片文件名及扩展名；重名文件自动编号，无文字图片跳过。"
        isExportingTexts = true
        Task { @MainActor in
            defer { isExportingTexts = false }
            guard await FileDialogs.response(to: panel) == .OK, let directory = panel.url else { return }
            let report = await Task.detached(priority: .userInitiated) {
                OCRTextExporter.export(snapshot, to: directory)
            }.value
            successMessage = report.savedURLs.isEmpty ? nil : report.message
            errorMessage = report.errors.isEmpty ? nil : report.errors.joined(separator: "\n")
        }
    }

    @MainActor
    func exportAsWord() {
        guard hasResult else { return }
        let text = allResultText
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.rtf]
        panel.nameFieldStringValue = "OCR识别结果.rtf"
        panel.title = "导出为 Word 兼容文档"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            guard let data = OCRService.exportAsRTF(text) else {
                self.errorMessage = "生成文档失败"
                return
            }
            do {
                try data.write(to: url, options: .atomic)
                self.successMessage = "已导出为 Word 兼容文档（RTF 格式）"
            } catch { self.errorMessage = "导出失败: \(error.localizedDescription)" }
        }
    }
#endif

    @MainActor
    func triggerTranslation() {
        guard hasText, !isTranslating else { return }
        isTranslating = true
        let revision = UUID()
        translationRevision = revision
        let inputs: [(id: String, text: String)] = imageResults.isEmpty
            ? [("single", recognizedText)]
            : imageResults.filter(\.hasText).map { ($0.id.uuidString, $0.text) }
        if #available(macOS 15.0, *) {
            translationTask = Task { await performTranslation(inputs: inputs, revision: revision) }
        } else {
            isTranslating = false
            errorMessage = "翻译功能需要 macOS 15.0 或更高版本"
        }
    }

    @available(macOS 15.0, *)
    @MainActor
    private func performTranslation(inputs: [(id: String, text: String)], revision: UUID) async {
        await waitForTranslationSession()
        guard translationRevision == revision, !Task.isCancelled else { return }
        guard translationSession != nil else {
            isTranslating = false
            errorMessage = "翻译服务尚未就绪，请重试"
            return
        }
        do {
            let responses = try await translateInputs(inputs)
            guard translationRevision == revision, !Task.isCancelled else { return }
            // 依据稳定标识匹配，不依赖返回顺序或同名文件。
            let translations = responses.compactMap { response -> (String, String)? in
                guard let id = response.clientIdentifier else { return nil }
                return (id, response.targetText)
            }
            applyTranslations(translations, inputs: inputs)
            isTranslating = false
            if translations.count == inputs.count {
                successMessage = "翻译完成"
            } else { errorMessage = "部分译文未返回，请重试" }
        } catch {
            guard translationRevision == revision, !Task.isCancelled else { return }
            isTranslating = false
            errorMessage = "翻译失败: \(error.localizedDescription)"
        }
    }

    // SDK 15 的 Request 未声明 Sendable，在非隔离执行器中创建并交给翻译服务。
    @available(macOS 15.0, *)
    private func translateInputs(_ inputs: [(id: String, text: String)]) async throws -> [TranslationSession.Response] {
        guard let session = translationSession else { return [] }
        let requests = inputs.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
        return try await session.translations(from: requests)
    }

    /// 同时核对标识与原文快照，防止编辑后的文字收到旧译文。
    func applyTranslations(_ translations: [(String, String)], inputs: [(id: String, text: String)]) {
        for (id, translation) in translations {
            guard let input = inputs.first(where: { $0.id == id }) else { continue }
            if id == "single" {
                if imageResults.isEmpty, recognizedText == input.text { translatedText = translation }
            } else if let index = imageResults.firstIndex(where: { $0.id.uuidString == id }), imageResults[index].text == input.text {
                imageResults[index].translatedText = translation
            }
        }
    }

    private func invalidateTranslation() {
        translationRevision = UUID()
        translationTask?.cancel()
        translationTask = nil
        isTranslating = false
    }

    private func resetResults() {
        invalidateTranslation()
        recognizedText = ""
        translatedText = ""
        imageResults = []
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
