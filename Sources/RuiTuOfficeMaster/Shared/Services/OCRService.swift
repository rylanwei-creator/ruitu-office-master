import Foundation
import Vision
import ImageIO
import CoreImage
import PDFKit
import UniformTypeIdentifiers

// MARK: - OCR 文字识别服务

/// 基于 Apple Vision 框架的离线 OCR 识别服务
/// 全程本地运行，无需联网、无需第三方 SDK
struct OCRService {

    // MARK: 支持的图片格式

    static let supportedFormats: [UTType] = [
        .jpeg, .png, .heic, .webP, .bmp, .tiff
    ]

    /// 支持导入的 PDF 格式
    static let pdfFormat: UTType = .pdf

    /// 所有支持的文件格式（图片 + PDF）
    static var allSupportedFormats: [UTType] {
        supportedFormats + [pdfFormat]
    }

    // MARK: 支持的语言

    /// 支持的语言（第一版仅中英文）
    static let supportedLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁体中文"),
        ("en-US", "英语"),
    ]

    /// 默认识别语言（简体中文 + 英语，覆盖绝大多数场景）
    static let defaultLanguages = ["zh-Hans", "en-US"]

    /// 自动识别标识（非真实语言代码，仅用于 UI 传参）
    static let autoDetectIdentifier = "auto"

    // MARK: 图片预处理

    /// 预处理配置
    struct PreprocessOptions {
        /// 是否启用图片增强（默认开启）
        var enhanceImage: Bool = true
        /// 亮度提升（0 = 不调整，推荐 0.05~0.15 用于暗光照片）
        var brightness: Float = 0.08
        /// 对比度提升（1.0 = 不调整，推荐 1.05~1.2）
        var contrast: Float = 1.1
    }

    /// 对图片做 OCR 友好增强：提亮、加对比度、去阴影
    /// - Parameters:
    ///   - image: 原始图片
    ///   - options: 预处理参数
    /// - Returns: 增强后的图片（若无需增强则返回原图）
    func preprocessImage(_ image: CGImage, options: PreprocessOptions = PreprocessOptions()) -> CGImage {
        guard options.enhanceImage else { return image }

        var ciImage = CIImage(cgImage: image)

        // 亮度 + 对比度调整
        if options.brightness != 0 || options.contrast != 1.0 {
            if let colorFilter = CIFilter(name: "CIColorControls") {
                colorFilter.setValue(ciImage, forKey: kCIInputImageKey)
                colorFilter.setValue(options.brightness, forKey: "inputBrightness")
                colorFilter.setValue(options.contrast, forKey: "inputContrast")
                if let output = colorFilter.outputImage {
                    ciImage = output
                }
            }
        }

        // 阴影/高光调整（提亮暗部）
        if let highlightFilter = CIFilter(name: "CIHighlightShadowAdjust") {
            highlightFilter.setValue(ciImage, forKey: kCIInputImageKey)
            highlightFilter.setValue(0.3, forKey: "inputShadowAmount")
            if let output = highlightFilter.outputImage {
                ciImage = output
            }
        }

        // 渲染输出
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let outputCG = context.createCGImage(ciImage, from: ciImage.extent) else {
            return image
        }
        return outputCG
    }

    // MARK: 图片加载

    /// 从文件路径加载 CGImage（跨平台兼容）
    func loadImage(from url: URL) throws -> CGImage {
        let original = try ImageCodec.dimensions(at: url)
        let size = try ImageCodec.outputSize(original: original, maxDimension: 4096, targetSize: nil, fitWithin: nil)
        return try ImageCodec.load(at: url, size: size)
    }

    // MARK: 文字识别

    /// 识别图片中的文字
    func recognizeText(
        from image: CGImage,
        languages: [String] = OCRService.defaultLanguages,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        preprocess: Bool = true
    ) async throws -> String {
        // 预处理增强
        let processedImage = preprocess
            ? preprocessImage(image)
            : image

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        // "auto" 标识 → 自动检测图片中的所有语言（限于中英文）
        let isAutoDetect = languages.contains(OCRService.autoDetectIdentifier)
        request.recognitionLanguages = isAutoDetect ? OCRService.defaultLanguages : languages
        request.automaticallyDetectsLanguage = isAutoDetect

        let handler = VNImageRequestHandler(cgImage: processedImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw OCRError.noTextFound
        }

        let sorted = observations.sorted { a, b in
            let ay = a.boundingBox.origin.y + a.boundingBox.size.height
            let by = b.boundingBox.origin.y + b.boundingBox.size.height
            if abs(ay - by) < 0.02 {
                return a.boundingBox.origin.x < b.boundingBox.origin.x
            }
            return ay > by
        }

        return mergeObservations(sorted)
    }

    /// 手写增强识别：针对手写/混合内容优化
    /// 与普通识别区别：强制 accurate 模式、关闭语言纠错（手写语法不规范）、
    /// 预处理增强对比度
    func recognizeHandwrittenText(
        from image: CGImage,
        languages: [String] = OCRService.defaultLanguages
    ) async throws -> String {
        // 手写增强预处理：更高对比度
        var options = PreprocessOptions()
        options.contrast = 1.25
        options.brightness = 0.1
        let enhanced = preprocessImage(image, options: options)

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate  // 手写必须高精度
        request.usesLanguageCorrection = false // 手写语法不规范，关闭纠错
        let isAutoDetect = languages.contains(OCRService.autoDetectIdentifier)
        request.recognitionLanguages = isAutoDetect ? OCRService.defaultLanguages : languages
        request.automaticallyDetectsLanguage = isAutoDetect
        // 最小文本高度降低，捕获小字手写
        request.minimumTextHeight = 0.0

        let handler = VNImageRequestHandler(cgImage: enhanced, options: [:])
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw OCRError.noTextFound
        }

        let sorted = observations.sorted { a, b in
            let ay = a.boundingBox.origin.y + a.boundingBox.size.height
            let by = b.boundingBox.origin.y + b.boundingBox.size.height
            if abs(ay - by) < 0.02 {
                return a.boundingBox.origin.x < b.boundingBox.origin.x
            }
            return ay > by
        }

        return mergeObservations(sorted)
    }

    /// 识别图片中的文字（返回带位置信息的结果，预留第二版扩展）
    func recognizeTextWithConfidence(
        from image: CGImage,
        languages: [String] = OCRService.defaultLanguages
    ) async throws -> [(text: String, confidence: Float, boundingBox: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let isAutoDetect = languages.contains(OCRService.autoDetectIdentifier)
        request.recognitionLanguages = isAutoDetect ? OCRService.defaultLanguages : languages
        request.automaticallyDetectsLanguage = isAutoDetect

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            throw OCRError.noTextFound
        }

        let sorted = observations.sorted { a, b in
            let ay = a.boundingBox.origin.y + a.boundingBox.size.height
            let by = b.boundingBox.origin.y + b.boundingBox.size.height
            if abs(ay - by) < 0.02 {
                return a.boundingBox.origin.x < b.boundingBox.origin.x
            }
            return ay > by
        }

        return sorted.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return (candidate.string, candidate.confidence, obs.boundingBox)
        }
    }

    // MARK: PDF 识别

    /// 从 PDF 文件中提取所有页面为 CGImage
    private func renderPDFPage(_ page: PDFPage) throws -> CGImage {
        guard let ref = page.pageRef else { throw OCRError.invalidPDF }
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = CGSize(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
        guard size.width > 0, size.height > 0 else { throw OCRError.invalidPDF }
        let scale = min(2, 4096 / max(size.width, size.height))
        let width = max(1, Int(size.width * scale)), height = max(1, Int(size.height * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw OCRError.invalidPDF }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(target)
        context.concatenate(ref.getDrawingTransform(.mediaBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(ref)
        guard let image = context.makeImage() else { throw OCRError.invalidPDF }
        return image
    }
    func recognizePDF(url: URL, languages: [String] = OCRService.defaultLanguages, preprocess: Bool = true,
                      progressHandler: @escaping (Int, Int) -> Void) async throws -> String {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw OCRError.invalidPDF }
        guard document.pageCount > 0 else { throw OCRError.emptyPDF }
        var allText: [String] = []
        var foundText = false
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            progressHandler(index + 1, document.pageCount)
            guard let page = document.page(at: index) else { throw OCRError.invalidPDF }
            do {
                let text: String
                if let existing = page.string, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    text = existing
                } else {
                    let image = try autoreleasepool { try renderPDFPage(page) }
                    text = try await recognizeText(from: image, languages: languages, preprocess: preprocess)
                }
                allText.append("--- 第 \(index + 1) 页 ---\n\(text)")
                foundText = foundText || !text.isEmpty
            } catch OCRError.noTextFound { allText.append("--- 第 \(index + 1) 页（无文字） ---") }
        }
        guard foundText else { throw OCRError.noTextFound }
        return allText.joined(separator: "\n\n")
    }

    // MARK: 批量图片识别

    /// 批量识别保留来源，单张图片失败不会丢掉其他图片的结果。
    func recognizeBatchResults(
        urls: [URL],
        languages: [String] = OCRService.defaultLanguages,
        preprocess: Bool = true,
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws -> [OCRImageResult] {
        try await recognizeBatchResults(urls: urls, recognize: { url in
            let image = try loadImage(from: url)
            return try await recognizeText(from: image, languages: languages, preprocess: preprocess)
        }, progressHandler: progressHandler)
    }

    /// 引擎边界独立，便于验证批处理的来源、顺序及单文件错误隔离。
    func recognizeBatchResults(
        urls: [URL],
        recognize: (URL) async throws -> String,
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws -> [OCRImageResult] {
        var results: [OCRImageResult] = []
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            progressHandler(index + 1, urls.count)
            do {
                let text = try await recognize(url)
                results.append(OCRImageResult(sourceURL: url, text: text,
                    status: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .noText : .recognized))
            } catch is CancellationError {
                throw CancellationError()
            } catch OCRError.noTextFound {
                results.append(OCRImageResult(sourceURL: url, text: "", status: .noText))
            } catch {
                results.append(OCRImageResult(sourceURL: url, text: "", status: .failed(error.localizedDescription)))
            }
        }
        return results
    }

    /// 兼容需要汇总文本的调用方；界面使用结构化结果。
    func recognizeBatch(
        urls: [URL],
        languages: [String] = OCRService.defaultLanguages,
        preprocess: Bool = true,
        progressHandler: @escaping (Int, Int) -> Void
    ) async throws -> String {
        let results = try await recognizeBatchResults(urls: urls, languages: languages,
            preprocess: preprocess, progressHandler: progressHandler)
        guard !results.isEmpty else { throw OCRError.noTextFound }
        return OCRImageResult.combinedText(results)
    }

    // MARK: 智能文本后处理

    /// 将 Vision 识别观测结果合并为语义通顺的自然段落
    private func mergeObservations(_ observations: [VNRecognizedTextObservation]) -> String {
        guard !observations.isEmpty else { return "" }

        struct TextLine {
            var texts: [String] = []
            var yMin: CGFloat = 0
            var yMax: CGFloat = 0
        }

        let sameLineThreshold: CGFloat = 0.008
        var lines: [TextLine] = []
        for obs in observations {
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { continue }
            let yMin = obs.boundingBox.origin.y
            let yMax = obs.boundingBox.origin.y + obs.boundingBox.size.height

            if let lastIdx = lines.indices.last,
               abs(lines[lastIdx].yMax - yMax) < sameLineThreshold {
                lines[lastIdx].texts.append(text)
                lines[lastIdx].yMin = min(lines[lastIdx].yMin, yMin)
                lines[lastIdx].yMax = max(lines[lastIdx].yMax, yMax)
            } else {
                var line = TextLine()
                line.texts = [text]
                line.yMin = yMin
                line.yMax = yMax
                lines.append(line)
            }
        }

        guard !lines.isEmpty else { return "" }

        let lineHeights = lines.map { $0.yMax - $0.yMin }
        let avgLineHeight = lineHeights.reduce(0, +) / CGFloat(lines.count)

        var result = ""
        for i in 0..<lines.count {
            let lineText = lines[i].texts.joined(separator: " ")

            if i > 0 {
                let prevLine = lines[i - 1]
                let gap = prevLine.yMin - lines[i].yMax
                let relativeGap = avgLineHeight > 0 ? gap / avgLineHeight : 0
                let prevText = prevLine.texts.last ?? ""
                let prevEndsWithPunctuation = prevText.last.map { ch in
                    "。！？.!?\n".contains(ch)
                } ?? false
                let prevIsShort = prevText.count <= 8

                if prevIsShort && relativeGap > 1.0 {
                    result += "\n\n"
                } else if relativeGap > 2.0 {
                    result += "\n\n"
                } else if relativeGap > 1.3 {
                    result += "\n"
                } else if prevEndsWithPunctuation {
                    result += "\n"
                }
            }
            result += lineText
        }

        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 纯文本智能排版：将乱换行的文本重新规整为自然段落
    static func reformatText(_ rawText: String) -> String {
        let paragraphs = rawText.components(separatedBy: "\n\n")

        let formatted = paragraphs.map { paragraph -> String in
            let lines = paragraph.components(separatedBy: "\n")
            var merged: [String] = []

            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }

                if let lastIdx = merged.indices.last {
                    let lastLine = merged[lastIdx]
                    let lastChar = lastLine.last ?? Character(" ")
                    let endsWithPunctuation = "。！？.!?）\"」』》".contains(lastChar)

                    if endsWithPunctuation {
                        merged.append(trimmed)
                    } else {
                        let needsSpace = lastChar.isLetter
                            && (trimmed.first?.isLetter ?? false)
                        merged[lastIdx] = lastLine + (needsSpace ? " " : "") + trimmed
                    }
                } else {
                    merged.append(trimmed)
                }
            }

            return merged.joined(separator: "\n")
        }

        var result = formatted
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n\n")

        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: RTF 导出（Word 兼容）

    /// 将识别文本导出为 RTF 格式（Microsoft Word / Pages 可直接打开）
    #if os(macOS)
    static func exportAsRTF(_ text: String) -> Data? {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.textColor,
            ]
        )
        return try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
    #endif

    // 文件大小相关已统一收拢到 FileUtils
}

// MARK: - OCR 错误

enum OCRError: LocalizedError {
    case invalidImage
    case noTextFound
    case recognitionFailed
    case invalidPDF
    case emptyPDF

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取图片文件，请确认图片格式正确"
        case .noTextFound: return "图片中未检测到文字，请尝试更清晰的图片或手动调整光线"
        case .recognitionFailed: return "文字识别失败，请重试"
        case .invalidPDF: return "无法读取 PDF 文件，请确认文件未加密且格式正确"
        case .emptyPDF: return "PDF 文件中未找到可识别的页面内容"
        }
    }
}
