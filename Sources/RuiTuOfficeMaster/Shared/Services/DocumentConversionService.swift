import Foundation
import PDFKit
#if canImport(AppKit)
import AppKit
#endif
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - 文档转换错误

enum DocumentConversionError: LocalizedError {
    case unsupportedFormat(String)
    case readFailed(URL)
    case conversionFailed
    case writeFailed
    case noContent

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext):
            return "不支持的文件格式：\(ext)"
        case .readFailed(let url):
            return "无法读取文件：\(url.lastPathComponent)"
        case .conversionFailed:
            return "文档转换失败"
        case .writeFailed:
            return "写入输出文件失败"
        case .noContent:
            return "文档没有可提取的内容"
        }
    }
}

// MARK: - 转换方向

enum ConversionDirection: String, CaseIterable {
    case wordToPDF = "Word → PDF"
    case pdfToWord = "PDF → Word（提取文字）"
}

// MARK: - 文档转换服务

struct DocumentConversionService {

    // MARK: 支持格式

    static let wordFormats: [UTType] = [
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "doc") ?? .data,
    ].filter { $0 != .data }

    static let pdfFormats: [UTType] = [.pdf]

    static var allInputFormats: [UTType] {
        wordFormats + pdfFormats
    }

    // 工具方法：文件大小相关已统一收拢到 FileUtils

    // MARK: Word → PDF

    func wordToPDF(url: URL, outputURL: URL) throws {
        let ext = url.pathExtension.lowercased()
        let docType: NSAttributedString.DocumentType
        switch ext {
        case "docx":
            docType = .officeOpenXML
        case "doc":
            docType = .docFormat
        default:
            throw DocumentConversionError.unsupportedFormat(ext)
        }

        let data = try Data(contentsOf: url)
        let attrStr = try NSAttributedString(
            data: data,
            options: [.documentType: docType],
            documentAttributes: nil
        )

        guard attrStr.length > 0 else {
            throw DocumentConversionError.noContent
        }

        // 使用 CoreText CTFramesetter 直接绘制 PDF（无需 @MainActor）
        let pageWidth: CGFloat = 595.28
        let pageHeight: CGFloat = 841.89
        let margin: CGFloat = 72
        let contentWidth = pageWidth - margin * 2
        let contentHeight = pageHeight - margin * 2

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let pdfContext = CGContext(outputURL as CFURL, mediaBox: &mediaBox, nil) else {
            throw DocumentConversionError.conversionFailed
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attrStr as CFAttributedString)
        var currentIndex = 0
        let totalLength = attrStr.length

        while currentIndex < totalLength {
            pdfContext.saveGState()
            defer { pdfContext.restoreGState() }

            pdfContext.beginPDFPage(nil)

            pdfContext.textMatrix = .identity

            let pageRect = CGRect(x: margin, y: margin, width: contentWidth, height: contentHeight)
            let path = CGPath(rect: pageRect, transform: nil)

            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRange(location: currentIndex, length: 0),
                path,
                nil
            )
            CTFrameDraw(frame, pdfContext)

            let visibleRange = CTFrameGetVisibleStringRange(frame)
            if visibleRange.length == 0 { pdfContext.endPDFPage(); break }

            currentIndex = visibleRange.location + visibleRange.length

            pdfContext.endPDFPage()
        }

        pdfContext.closePDF()

        guard currentIndex == totalLength else {
            try? FileManager.default.removeItem(at: outputURL)
            throw DocumentConversionError.conversionFailed
        }
    }

    // MARK: PDF → Word

    func pdfToWord(url: URL, outputURL: URL) throws {
        guard let pdfDoc = PDFDocument(url: url) else {
            throw DocumentConversionError.readFailed(url)
        }

        guard !pdfDoc.isLocked else { throw PDFError.sourceEncrypted(url: url) }
        let mutableStr = NSMutableAttributedString()

        for i in 0..<pdfDoc.pageCount {
            if let page = pdfDoc.page(at: i),
               let pageAttrStr = page.attributedString {
                if i > 0 {
                    mutableStr.append(NSAttributedString(string: "\n\n"))
                }
                mutableStr.append(pageAttrStr)
            }
        }

        guard mutableStr.length > 0 else {
            throw DocumentConversionError.noContent
        }

        let range = NSRange(location: 0, length: mutableStr.length)
        guard let docData = try? mutableStr.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        ) else {
            throw DocumentConversionError.conversionFailed
        }

        try docData.write(to: outputURL, options: .atomic)
    }
}
