import Foundation
import PDFKit
import UniformTypeIdentifiers
import CoreGraphics
import AppKit

typealias PlatformFont = NSFont

// MARK: - PDF 错误

enum PDFError: LocalizedError {
    case invalidSource(url: URL)
    case sourceEncrypted(url: URL)
    case writeFailed
    case noPages
    case invalidPageRange(String)
    case watermarkFailed

    var errorDescription: String? {
        switch self {
        case .invalidSource(let url):
            return "无法读取 PDF 文件：\(url.lastPathComponent)"
        case .sourceEncrypted(let url):
            return "文件已加密，请先解密后再操作：\(url.lastPathComponent)"
        case .writeFailed:
            return "写入 PDF 文件失败"
        case .noPages:
            return "PDF 文件没有页面"
        case .invalidPageRange(let range):
            return "页码范围格式不正确：\(range)"
        case .watermarkFailed:
            return "添加水印失败"
        }
    }
}

// MARK: - 水印类型

enum WatermarkType {
    case text(String, fontSize: CGFloat, color: CGColor, rotation: CGFloat, opacity: CGFloat)
    case image(URL, scale: CGFloat, opacity: CGFloat)
}

// MARK: - 加密配置

struct EncryptionConfig: Sendable, Equatable {
    let userPassword: String
    let ownerPassword: String
    let allowPrinting: Bool
    let allowCopying: Bool
}

// MARK: - 拆分范围

struct SplitRange: Sendable, Equatable {
    let start: Int
    let end: Int
}

// MARK: - PDF 服务

struct PDFService {
    static let supportedFormats: [UTType] = [.pdf]
    private func load(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw PDFError.invalidSource(url: url) }
        guard !document.isLocked else { throw PDFError.sourceEncrypted(url: url) }
        guard document.pageCount > 0 else { throw PDFError.noPages }
        return document
    }
    private func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard let data = doc.dataRepresentation(options: options) else { throw PDFError.writeFailed }
        try data.write(to: url, options: .atomic)
    }
    func pageCount(of url: URL) -> Int { (try? load(url).pageCount) ?? 0 }
    func validate(url: URL) throws { _ = try load(url) }
    func merge(urls: [URL], outputURL: URL, shouldStop: () -> Bool = { false }) throws {
        guard !urls.contains(where: { $0.standardizedFileURL == outputURL.standardizedFileURL }) else { throw CompressionError.sameFile }
        let destination = PDFDocument()
        for url in urls {
            if shouldStop() { throw CancellationError() }
            let source = try load(url)
            for i in 0..<source.pageCount {
                if shouldStop() { throw CancellationError() }
                guard let page = source.page(at: i)?.copy() as? PDFPage else { throw PDFError.invalidSource(url: url) }
                destination.insert(page, at: destination.pageCount)
            }
        }
        guard destination.pageCount > 0 else { throw PDFError.noPages }
        if shouldStop() { throw CancellationError() }
        try write(destination, to: outputURL)
    }
    func split(url: URL, ranges: [SplitRange], outputDir: URL) throws -> [URL] {
        let document = try load(url)
        guard !ranges.isEmpty, ranges.allSatisfy({ $0.start >= 1 && $0.end >= $0.start && $0.end <= document.pageCount }) else {
            throw PDFError.invalidPageRange("页码必须位于 1 到 \(document.pageCount) 之间")
        }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        var output: [URL] = []
        for range in ranges {
            let chunk = PDFDocument()
            for index in (range.start - 1)..<range.end {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { throw PDFError.noPages }
                chunk.insert(page, at: chunk.pageCount)
            }
            let base = url.deletingPathExtension().lastPathComponent + "_第\(range.start)" + (range.start == range.end ? "页" : "-\(range.end)页")
            var dest = outputDir.appendingPathComponent(base + ".pdf")
            var counter = 1
            while FileManager.default.fileExists(atPath: dest.path) {
                dest = outputDir.appendingPathComponent(base + " (\(counter)).pdf"); counter += 1
            }
            try write(chunk, to: dest)
            output.append(dest)
        }
        return output
    }
    func encrypt(url: URL, config: EncryptionConfig, outputURL: URL) throws {
        guard url.standardizedFileURL != outputURL.standardizedFileURL else { throw CompressionError.sameFile }
        let document = try load(url)
        guard !config.userPassword.isEmpty else { throw PDFError.invalidPageRange("请输入打开密码") }
        guard config.ownerPassword.isEmpty || config.ownerPassword != config.userPassword else {
            throw PDFError.invalidPageRange("打开密码和权限密码不能相同")
        }
        let permissions = (config.allowPrinting ? 3 : 0) | (config.allowCopying ? 16 : 0)
        try write(document, to: outputURL, options: [
            .userPasswordOption: config.userPassword,
            .ownerPasswordOption: config.ownerPassword.isEmpty ? UUID().uuidString : config.ownerPassword,
            .accessPermissionsOption: NSNumber(value: permissions)
        ])
    }
    func addWatermark(url: URL, type: WatermarkType, outputURL: URL) throws {
        guard url.standardizedFileURL != outputURL.standardizedFileURL else { throw CompressionError.sameFile }
        let document = try load(url)
        let destination = PDFDocument()
        var watermarkImage: CGImage?
        if case .image(let imageURL, _, _) = type {
            let size = try ImageCodec.outputSize(original: ImageCodec.dimensions(at: imageURL), maxDimension: 2048, targetSize: nil, fitWithin: nil)
            watermarkImage = try ImageCodec.load(at: imageURL, size: size)
        }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let ref = page.pageRef else { throw PDFError.watermarkFailed }
            var mediaBox = page.bounds(for: .mediaBox)
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                  let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw PDFError.watermarkFailed }
            context.beginPDFPage(nil)
            context.drawPDFPage(ref)
            context.saveGState()
            switch type {
            case .text(let text, let fontSize, let color, let rotation, let opacity):
                guard !text.isEmpty, fontSize > 0, fontSize.isFinite, rotation.isFinite, opacity.isFinite else { throw PDFError.watermarkFailed }
                context.setAlpha(min(1, max(0, opacity)))
                context.translateBy(x: mediaBox.midX, y: mediaBox.midY)
                context.rotate(by: rotation * .pi / 180)
                let string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor(cgColor: color) ?? .gray])
                let line = CTLineCreateWithAttributedString(string)
                let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
                CTLineDraw(line, context)
            case .image(_, let scale, let opacity):
                guard let image = watermarkImage, scale.isFinite, scale > 0, opacity.isFinite else { throw PDFError.watermarkFailed }
                context.setAlpha(min(1, max(0, opacity)))
                let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
                context.draw(image, in: CGRect(x: mediaBox.midX - width / 2, y: mediaBox.midY - height / 2, width: width, height: height))
            }
            context.restoreGState()
            context.endPDFPage(); context.closePDF()
            guard let rendered = PDFDocument(data: data as Data), let newPage = rendered.page(at: 0) else { throw PDFError.watermarkFailed }
            newPage.rotation = page.rotation
            newPage.setBounds(page.bounds(for: .cropBox), for: .cropBox)
            for annotation in page.annotations where annotation.type != "Popup" {
                if let copy = annotation.copy() as? PDFAnnotation { newPage.addAnnotation(copy) }
            }
            destination.insert(newPage, at: destination.pageCount)
        }
        try write(destination, to: outputURL)
    }
}
