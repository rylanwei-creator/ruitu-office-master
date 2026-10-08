import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 图片格式互转服务

/// 支持的输出格式
enum ConversionFormat: String, CaseIterable, Sendable {
    case jpg = "JPG"
    case png = "PNG"
    case webp = "WebP"
    case heic = "HEIC"
    case bmp = "BMP"
    case tiff = "TIFF"

    var uti: CFString {
        switch self {
        case .jpg:  return UTType.jpeg.identifier as CFString
        case .png:  return UTType.png.identifier as CFString
        case .webp: return UTType.webP.identifier as CFString
        case .heic: return UTType.heic.identifier as CFString
        case .bmp:  return UTType.bmp.identifier as CFString
        case .tiff: return UTType.tiff.identifier as CFString
        }
    }

    static var available: [Self] { allCases.filter { ImageCodec.writableTypes.contains($0.uti as String) } }

    var fileExtension: String {
        rawValue.lowercased()
    }
}

/// 支持的源格式（比输出格式更宽，允许 HEIF 等变体）
struct FormatConversionService {

    static let supportedInputFormats: [UTType] = [
        .jpeg, .png, .webP, .heic, .heif, .bmp, .tiff
    ]

    /// 将图片从源格式转换为目标格式
    func convert(url: URL, to targetFormat: ConversionFormat, outputURL: URL) throws {
        try ImageCodec.convert(at: url, type: UTType(targetFormat.uti as String) ?? .image,
                               quality: 0.9, outputURL: outputURL)
    }

    // 文件大小相关已统一收拢到 FileUtils
}

// MARK: - 转换错误

enum ConversionError: LocalizedError {
    case invalidSource
    case cannotCreateOutput
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .invalidSource: return "无法读取源图片文件"
        case .cannotCreateOutput: return "无法创建输出文件"
        case .writeFailed: return "写入转换文件失败"
        }
    }
}
