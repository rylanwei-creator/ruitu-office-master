import Foundation
import AppKit
import CoreImage
import Vision

struct CutoutResult: Sendable { let image: CGImage; let subjects: Int }

enum ImageCleanupService {
    static func prepare(_ url: URL) throws -> CleanupImageAsset {
        try Task.checkCancellation()
        try ImageCodec.validateStaticImage(at: url)
        let original = try ImageCodec.dimensions(at: url)
        let image = try ImageCodec.load(at: url, size: CGSize(width: 4096, height: 4096))
        try Task.checkCancellation()
        return CleanupImageAsset(image: image, originalSize: original)
    }

    static func cutout(_ image: CGImage) throws -> CutoutResult {
        try Task.checkCancellation()
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
            try Task.checkCancellation()
            guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
                throw CleanupError.message("没有识别到明确的前景主体，请换一张主体与背景区分清晰的图片。")
            }
            let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances,
                from: handler, croppedToInstancesExtent: false)
            let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
            let ci = CIImage(cvPixelBuffer: buffer)
            guard let result = context.createCGImage(ci, from: ci.extent) else { throw CompressionError.renderFailed }
            try Task.checkCancellation()
            return CutoutResult(image: result, subjects: observation.allInstances.count)
        } catch is CancellationError { throw CancellationError() }
        catch let error as CleanupError { throw error }
        catch { throw CleanupError.message("本机自动抠图未完成：\(error.localizedDescription)\n请检查系统前景分割能力，或换一张主体更清晰的图片。") }
    }

    /// 取样与羽化滤镜用于图片局部修补。
    static func sampledRepair(_ image: CIImage, region: CleanupRegion, sampleCenter: CGPoint, feather: Double) throws -> CIImage {
        guard feather.isFinite, (0...20).contains(feather) else { throw CleanupError.message("羽化参数无效。") }
        let extent = image.extent
        let size = extent.size
        let top = try region.pixels(in: size)
        let sample = try region.sampleRegion(center: sampleCenter)
        let src = try sample.pixels(in: size)
        let target = CGRect(x: extent.minX + top.minX, y: extent.maxY - top.maxY, width: top.width, height: top.height)
        // 区域按像素取整时宽度可能差 1 像素；统一以目标尺寸取样，避免拉伸。
        let source = CGRect(x: extent.minX + src.minX, y: extent.maxY - src.minY - target.height,
                            width: target.width, height: target.height)
        guard extent.contains(source) else { throw CleanupError.message("取样区域超出图片边缘。") }
        let patch = image.cropped(to: source).transformed(by: CGAffineTransform(translationX: target.minX - source.minX, y: target.minY - source.minY))
        guard let rectangle = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: target), "inputRadius": 0,
            "inputColor": CIColor.white
        ])?.outputImage else { throw CompressionError.renderFailed }
        let radius = min(min(target.width, target.height) / 8, feather)
        let mask = (radius > 0 ? rectangle.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]) : rectangle)
            .cropped(to: target).composited(over: CIImage(color: .black).cropped(to: extent))
        let blended = patch.clampedToExtent().applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask
        ])
        return blended.cropped(to: extent)
    }

    static func sample(_ image: CGImage, region: CleanupRegion, center: CGPoint, feather: Double) throws -> CGImage {
        try Task.checkCancellation()
        let output = try sampledRepair(CIImage(cgImage: image), region: region, sampleCenter: center, feather: feather)
        guard let result = CIContext().createCGImage(output, from: output.extent)
            ?? CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent) else { throw CompressionError.renderFailed }
        try Task.checkCancellation()
        return result
    }

    /// 简单背景使用边界颜色插值修补；只修改选区，不承诺恢复遮挡细节。
    static func surrounding(_ image: CGImage, region: CleanupRegion) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let rect = try region.pixels(in: size)
        guard rect.width * rect.height <= 1_000_000 else {
            throw CleanupError.message("选区过大，请分成较小区域修补，或改用取样修补。")
        }
        let width = image.width, height = image.height
        let bytesPerRow = width * 4
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            let memory = context.data else { throw CompressionError.renderFailed }
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let pixels = memory.assumingMemoryBound(to: UInt8.self)
        let original = Array(UnsafeBufferPointer(start: pixels, count: bytesPerRow * height))
        let x0 = Int(rect.minX), x1 = Int(rect.maxX), y0 = Int(rect.minY), y1 = Int(rect.maxY)
        guard x0 > 0 || x1 < width || y0 > 0 || y1 < height else {
            throw CleanupError.message("不能修补整张图片，请只框选水印，并保留周边干净背景。")
        }
        for y in y0..<y1 {
            try Task.checkCancellation()
            for x in x0..<x1 {
                // 只使用存在的边界，不采集选区自身作为背景。
                var samples: [(offset: Int, weight: Double)] = []
                if x0 > 0 { samples.append(((y * width + x0 - 1) * 4, 1 / Double(x - x0 + 1))) }
                if x1 < width { samples.append(((y * width + x1) * 4, 1 / Double(x1 - x))) }
                if y0 > 0 { samples.append((((y0 - 1) * width + x) * 4, 1 / Double(y - y0 + 1))) }
                if y1 < height { samples.append(((y1 * width + x) * 4, 1 / Double(y1 - y))) }
                let weight = samples.reduce(0) { $0 + $1.weight }
                for channel in 0..<4 {
                    let sum = samples.reduce(0.0) { $0 + Double(original[$1.offset + channel]) * $1.weight }
                    pixels[(y * width + x) * 4 + channel] = UInt8(min(255, max(0, (sum / weight).rounded())))
                }
            }
        }
        guard let result = context.makeImage() else { throw CompressionError.renderFailed }
        return result
    }

    static func erase(_ image: CGImage, region: CleanupRegion) throws -> CGImage {
        try Task.checkCancellation()
        let rect = try region.pixels(in: CGSize(width: image.width, height: image.height))
        let context = try rgbaContext(image)
        context.clear(CGRect(x: rect.minX, y: Double(image.height) - rect.maxY, width: rect.width, height: rect.height))
        guard let result = context.makeImage() else { throw CompressionError.renderFailed }
        return result
    }
    private static func rgbaContext(_ image: CGImage) throws -> CGContext {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CompressionError.renderFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }
}
