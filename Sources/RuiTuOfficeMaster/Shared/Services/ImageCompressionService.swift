import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

struct CompressionResult: Sendable {
    let originalURL: URL
    let compressedURL: URL
    let originalSize: Int64
    let compressedSize: Int64
    var compressionRatio: Double { originalSize > 0 ? Double(compressedSize) / Double(originalSize) : 1 }
    var savedPercent: Int { Int((1 - compressionRatio) * 100) }
    var changeText: String { savedPercent >= 0 ? "减少 \(savedPercent)%" : "增加 \(-savedPercent)%" }
}

struct ImageCompressionService {
    static let supportedFormats: [UTType] = [.jpeg, .png, .heic, .heif, .webP, .bmp, .tiff]

    func outputType(for format: OutputFormat, originalURL: URL) throws -> UTType {
        let type: UTType
        switch format {
        case .keepOriginal: type = try ImageCodec.sourceType(at: originalURL)
        case .jpg: type = .jpeg
        case .png: type = .png
        case .webp: type = .webP
        case .heic: type = .heic
        }
        guard ImageCodec.supports(type) else {
            throw CompressionError.unsupportedOutput(type.preferredFilenameExtension ?? type.identifier)
        }
        return type
    }

    func compress(url: URL, quality: Double, maxDimension: CGFloat?, outputFormat: OutputFormat,
                  outputURL: URL, targetSize: CGSize? = nil, fitWithin: CGSize? = nil) throws {
        try ImageCodec.convert(at: url, type: outputType(for: outputFormat, originalURL: url), quality: quality,
                               maxDimension: maxDimension, targetSize: targetSize, fitWithin: fitWithin, outputURL: outputURL)
    }

    /// 按目标尺寸完整编码并读取字节数，不能从缩略图体积按面积推算。
    func estimateCompressedSize(url: URL, quality: Double, maxDimension: CGFloat?, outputFormat: OutputFormat,
                                targetSize: CGSize? = nil, fitWithin: CGSize? = nil) throws -> Int64 {
        let type = try outputType(for: outputFormat, originalURL: url)
        let data = try ImageCodec.convertedData(at: url, type: type, quality: quality,
            maxDimension: maxDimension, targetSize: targetSize, fitWithin: fitWithin)
        return Int64(data.count)
    }
}

/// 后台预估与批处理共用串行执行器，过期请求在解码前退出，限制大图并发内存。
actor ImageCompressionWorker {
    static let shared = ImageCompressionWorker()

    func estimate(url: URL, quality: Double, maxDimension: CGFloat?, outputFormat: OutputFormat,
                  targetSize: CGSize?, fitWithin: CGSize?) throws -> Int64 {
        try Task.checkCancellation()
        return try autoreleasepool {
            try ImageCompressionService().estimateCompressedSize(url: url, quality: quality, maxDimension: maxDimension,
                outputFormat: outputFormat, targetSize: targetSize, fitWithin: fitWithin)
        }
    }

    func convert(url: URL, format: ConversionFormat, outputURL: URL) throws {
        try Task.checkCancellation()
        try autoreleasepool { try FormatConversionService().convert(url: url, to: format, outputURL: outputURL) }
    }

    func compress(url: URL, quality: Double, maxDimension: CGFloat?, outputFormat: OutputFormat,
                  outputURL: URL, targetSize: CGSize?, fitWithin: CGSize?) throws {
        try Task.checkCancellation()
        try autoreleasepool {
            try ImageCompressionService().compress(url: url, quality: quality, maxDimension: maxDimension,
                outputFormat: outputFormat, outputURL: outputURL, targetSize: targetSize, fitWithin: fitWithin)
        }
    }
}

enum CompressionError: LocalizedError {
    case invalidImage, renderFailed, cannotCreateOutput, writeFailed
    case cannotCreateSession, exportCancelled, noVideoTrack, invalidQuality
    case invalidDimensions, imageTooLarge, sameFile
    case unsupportedOutput(String)
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取图片，请确认文件完整且为支持的图片格式"
        case .renderFailed: return "图片处理失败"
        case .cannotCreateOutput: return "无法创建输出文件"
        case .writeFailed: return "图片编码失败，请尝试 JPG 或 PNG 格式"
        case .cannotCreateSession: return "无法创建视频处理会话"
        case .exportCancelled: return "视频处理失败或已取消"
        case .noVideoTrack: return "文件中没有可处理的视频轨道"
        case .invalidQuality: return "质量参数必须在 0 到 1 之间"
        case .invalidDimensions: return "请输入有效尺寸：单边最多 16384 像素，总像素不超过 4000 万"
        case .imageTooLarge: return "图片尺寸过大，请选择限定最大边长后重试"
        case .sameFile: return "输出路径不能与原文件相同"
        case .unsupportedOutput(let format): return "本机不支持 \(format.uppercased()) 编码，请改用 JPG 或 PNG 输出"
        }
    }
}
