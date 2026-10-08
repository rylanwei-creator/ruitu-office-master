import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// 图片读写统一入口：纠正 EXIF 方向，限制解码内存，显式处理透明度。
enum ImageCodec {
    static let writableTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    static func supports(_ type: UTType) -> Bool { writableTypes.contains(type.identifier) }

    static func sourceType(at url: URL) throws -> UTType {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let identifier = CGImageSourceGetType(source) else { throw CompressionError.invalidImage }
        return UTType(identifier as String) ?? .image
    }

    static func validateStaticImage(at url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CompressionError.invalidImage }
        guard CGImageSourceGetCount(source) == 1 else {
            throw NSError(domain: "RuiTuImage", code: 10, userInfo: [NSLocalizedDescriptionKey: "不支持多帧或多页图片；动态图请使用 GIF 工具，避免只保留第一帧"])
        }
    }
    static func dimensions(at url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              w.doubleValue > 0, h.doubleValue > 0 else { throw CompressionError.invalidImage }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: h.doubleValue, height: w.doubleValue)
            : CGSize(width: w.doubleValue, height: h.doubleValue)
    }

    static func outputSize(original: CGSize, maxDimension: CGFloat?, targetSize: CGSize?, fitWithin: CGSize?) throws -> CGSize {
        if let size = targetSize {
            guard size.width.isFinite, size.height.isFinite,
                  size.width >= 1, size.height >= 1,
                  size.width <= 16384, size.height <= 16384,
                  size.width * size.height <= 40_000_000 else { throw CompressionError.invalidDimensions }
            return CGSize(width: size.width.rounded(), height: size.height.rounded())
        }
        var scale: CGFloat = 1
        if let limit = maxDimension {
            guard limit.isFinite, limit >= 1 else { throw CompressionError.invalidDimensions }
            scale = min(scale, limit / max(original.width, original.height))
        }
        if let box = fitWithin {
            guard box.width.isFinite, box.height.isFinite, box.width >= 1, box.height >= 1 else {
                throw CompressionError.invalidDimensions
            }
            scale = min(scale, box.width / original.width, box.height / original.height)
        }
        let result = CGSize(width: max(1, floor(original.width * scale)), height: max(1, floor(original.height * scale)))
        guard result.width * result.height <= 40_000_000 else { throw CompressionError.imageTooLarge }
        return result
    }

    static func load(at url: URL, size: CGSize) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CompressionError.invalidImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(max(size.width, size.height)),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw CompressionError.renderFailed
        }
        return image
    }

    static func render(_ image: CGImage, size: CGSize, flattenAlpha: Bool) throws -> CGImage {
        let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info) else {
            throw CompressionError.renderFailed
        }
        let rect = CGRect(origin: .zero, size: size)
        if flattenAlpha {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
        }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw CompressionError.renderFailed }
        return result
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double) throws -> Data {
        guard quality.isFinite, (0...1).contains(quality) else { throw CompressionError.invalidQuality }
        guard supports(type) else { throw CompressionError.unsupportedOutput(type.preferredFilenameExtension ?? type.identifier) }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CompressionError.cannotCreateOutput
        }
        var options: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        // PNG 不做颜色量化。质量参数只应用于有损格式。
        if type != .png && type != .tiff && type != .bmp {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest), data.length > 0 else { throw CompressionError.writeFailed }
        return data as Data
    }

    /// 预估和导出必须使用相同的尺寸、渲染和完整编码流程。
    static func convertedData(at url: URL, type: UTType, quality: Double,
                              maxDimension: CGFloat? = nil, targetSize: CGSize? = nil,
                              fitWithin: CGSize? = nil) throws -> Data {
        try Task.checkCancellation()
        try validateStaticImage(at: url)
        let original = try dimensions(at: url)
        let size = try outputSize(original: original, maxDimension: maxDimension, targetSize: targetSize, fitWithin: fitWithin)
        let decoded = try load(at: url, size: size)
        try Task.checkCancellation()
        let image = try render(decoded, size: size, flattenAlpha: type == .jpeg || type == .bmp)
        try Task.checkCancellation()
        return try encode(image, type: type, quality: quality)
    }

    static func convert(at url: URL, type: UTType, quality: Double,
                        maxDimension: CGFloat? = nil, targetSize: CGSize? = nil,
                        fitWithin: CGSize? = nil, outputURL: URL) throws {
        guard url.standardizedFileURL != outputURL.standardizedFileURL else { throw CompressionError.sameFile }
        let data = try convertedData(at: url, type: type, quality: quality, maxDimension: maxDimension,
                                     targetSize: targetSize, fitWithin: fitWithin)
        try data.write(to: outputURL, options: .atomic)
    }
}
