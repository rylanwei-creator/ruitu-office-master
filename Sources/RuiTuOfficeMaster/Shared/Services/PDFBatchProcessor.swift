import Foundation
import CoreGraphics

/// A stop request is checked between merge pages. Other operations finish their current output.
final class PDFStopToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func requestStop() { lock.lock(); defer { lock.unlock() }; stopped = true }
    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

enum PDFEntryState: String, Sendable {
    case waiting = "等待中"
    case processing = "处理中"
    case ready = "已检查，等待合并"
    case succeeded = "成功"
    case failed = "失败"
    case blocked = "未合并"
    case stopped = "未处理（已停止）"
    var canRetry: Bool { self == .failed || self == .stopped || self == .blocked }
}

struct PDFBatchEntry: Identifiable, Sendable {
    let id = UUID()
    let sourceURL: URL
    let range: SplitRange?
    var state: PDFEntryState = .waiting
    var error: String?
    var title: String {
        guard let range else { return sourceURL.lastPathComponent }
        return sourceURL.lastPathComponent + " · 第\(range.start)" + (range.start == range.end ? "页" : "–\(range.end)页")
    }
}

enum PDFWatermarkConfiguration: Sendable, Equatable {
    case text(String, size: CGFloat, rotation: Double, opacity: Double)
    case image(URL, opacity: Double)
    var watermark: WatermarkType {
        switch self {
        case let .text(text, size, rotation, opacity):
            return .text(text, fontSize: size, color: CGColor(gray: 0.5, alpha: 1), rotation: rotation, opacity: opacity)
        case let .image(url, opacity): return .image(url, scale: 0.3, opacity: opacity)
        }
    }
}

enum PDFBatchConfiguration: Sendable, Equatable {
    case merge
    case split
    case encrypt(EncryptionConfig)
    case watermark(PDFWatermarkConfiguration)
    case conversion(ConversionDirection)
    var title: String {
        switch self {
        case .merge: "合并"
        case .split: "拆分"
        case .encrypt: "加密"
        case .watermark: "水印"
        case let .conversion(direction): direction.rawValue
        }
    }
}

struct PDFProcessingJob: Sendable {
    let sources: [URL]
    let range: SplitRange?
}

enum PDFBatchProcessor {
    static func freshFileSize(_ url: URL) -> Int64 {
        // URL resource values can retain the pre-repair size across a retry.
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
    /// Runs on a background task. Each output owns a directory, including same-named sources/ranges.
    static func process(_ job: PDFProcessingJob, configuration: PDFBatchConfiguration, stop: PDFStopToken) throws -> [PDFResultItem] {
        guard let source = job.sources.first else { throw PDFError.noPages }
        let inputSize = job.sources.reduce(Int64(0)) { $0 + freshFileSize($1) }
        let directory = try CacheManager.makeTaskDirectory(in: CacheManager.documentCacheDirectory)
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: directory) } }
        let name = source.deletingPathExtension().lastPathComponent
        let service = PDFService()
        let output: [URL]
        switch configuration {
        case .merge:
            let url = directory.appendingPathComponent("合并文档.pdf")
            try service.merge(urls: job.sources, outputURL: url, shouldStop: { stop.isStopped })
            output = [url]
        case .split:
            guard let range = job.range else { throw PDFError.invalidPageRange("没有拆分范围") }
            output = try service.split(url: source, ranges: [range], outputDir: directory)
        case let .encrypt(config):
            let url = directory.appendingPathComponent("\(name)_加密.pdf")
            try service.encrypt(url: source, config: config, outputURL: url)
            output = [url]
        case let .watermark(config):
            let url = directory.appendingPathComponent("\(name)_水印.pdf")
            try service.addWatermark(url: source, type: config.watermark, outputURL: url)
            output = [url]
        case let .conversion(direction):
            let ext = direction == .wordToPDF ? "pdf" : "docx"
            let url = directory.appendingPathComponent("\(name)_转换.\(ext)")
            if direction == .wordToPDF {
                try DocumentConversionService().wordToPDF(url: source, outputURL: url)
            } else {
                try DocumentConversionService().pdfToWord(url: source, outputURL: url)
            }
            output = [url]
        }
        let results = output.map { PDFResultItem(originalURL: source, outputURL: $0,
            originalSize: inputSize, outputSize: FileUtils.fileSize(of: $0), operationDescription: configuration.title) }
        complete = true
        return results
    }
}
