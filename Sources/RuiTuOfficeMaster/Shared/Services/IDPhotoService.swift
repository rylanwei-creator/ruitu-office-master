import Foundation
import CoreGraphics
import ImageIO
import Vision
import UniformTypeIdentifiers

struct IDPhotoAsset: Sendable {
    let id: UUID
    let image: CGImage
    let faces: [CGRect] // 左上原点，像素坐标
    let originalSize: CGSize
    let faceDetectionFailed: Bool
    var size: CGSize { CGSize(width: image.width, height: image.height) }
}
struct IDPhotoResult: Sendable {
    let data: Data
    let image: CGImage // 从最终编码数据解码，预览与保存一致
    let editorImage: CGImage
    let settings: IDPhotoSettings
    let cropRect: CGRect
}

/// 预览栅格来自同一份待导出的 PDF，屏幕缩放不改变打印尺寸。
struct IDPhotoPrintPreview: Sendable {
    let data: Data
    let image: CGImage
    let settings: IDPhotoSettings
    let paper: IDPhotoPaper
    let cropMarks: Bool
    let photoCount: Int
}

/// 串行处理与遮罩缓存，拖动裁切或切换底色不重复运行人像分割。
actor IDPhotoWorker {
    static let shared = IDPhotoWorker()
    private var maskID: UUID?
    private var mask: CGImage?
    private var compositeAssetID: UUID?
    private var compositeKey: IDPhotoSettings?
    private var compositeImage: CGImage?

    func prepare(url: URL, quarterTurns: Int = 0) throws -> IDPhotoAsset {
        try Task.checkCancellation()
        try ImageCodec.validateStaticImage(at: url)
        let originalSize = try ImageCodec.dimensions(at: url)
        let decoded = try ImageCodec.load(at: url, size: CGSize(width: 4096, height: 4096))
        let turns = ((quarterTurns % 4) + 4) % 4
        let image = try IDPhotoService.rotate(decoded, quarterTurns: turns)
        try Task.checkCancellation()
        let request = VNDetectFaceRectanglesRequest()
        var faces: [CGRect] = []
        var failed = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            faces = (request.results ?? []).map { observation in
                let b = observation.boundingBox
                return CGRect(x: b.minX * Double(image.width), y: (1 - b.maxY) * Double(image.height),
                              width: b.width * Double(image.width), height: b.height * Double(image.height))
            }
        } catch { failed = true }
        try Task.checkCancellation()
        mask = nil; maskID = nil; compositeKey = nil; compositeImage = nil
        return IDPhotoAsset(id: UUID(), image: image, faces: faces,
                            originalSize: turns % 2 == 0 ? originalSize : CGSize(width: originalSize.height, height: originalSize.width),
                            faceDetectionFailed: failed)
    }

    func render(asset: IDPhotoAsset, settings: IDPhotoSettings) throws -> IDPhotoResult {
        try Task.checkCancellation()
        try settings.validate()
        var image = asset.image
        if let color = settings.backgroundColor {
            guard asset.faces.count == 1 else {
                throw IDPhotoError.message(asset.faces.count > 1
                    ? "照片中检测到多张人脸，请换用单人照片；也可以保留原背景进行裁切。"
                    : "未识别到单人正面人脸，暂不能自动换底。可保留原背景裁切，或更换清晰正面照片。")
            }
            if maskID != asset.id || mask == nil {
                let request = VNGeneratePersonSegmentationRequest()
                request.qualityLevel = .accurate
                request.outputPixelFormat = kCVPixelFormatType_OneComponent8
                do {
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    guard let buffer = request.results?.first?.pixelBuffer else {
                        throw IDPhotoError.message("没有获得人像遮罩。")
                    }
                    mask = try IDPhotoService.maskImage(buffer)
                    maskID = asset.id
                } catch {
                    throw IDPhotoError.message("本机人像分割未能完成：\(error.localizedDescription)\n请改用保留原背景，或更换清晰单人照片后重试。")
                }
            }
            try Task.checkCancellation()
            guard let mask else { throw CompressionError.renderFailed }
            if let key = compositeKey, let cached = compositeImage, compositeAssetID == asset.id,
               key.background == settings.background, key.red == settings.red, key.green == settings.green, key.blue == settings.blue {
                image = cached
            } else {
                image = try IDPhotoService.composite(image: image, mask: mask, color: color)
                compositeImage = image; compositeKey = settings; compositeAssetID = asset.id
            }
        }
        let rect = settings.crop.rect(in: asset.size, aspect: settings.millimeters.width / settings.millimeters.height)
        let cropped = try IDPhotoService.crop(image: image, rect: rect, output: settings.pixelSize)
        try Task.checkCancellation()
        let data = try IDPhotoService.encode(cropped, settings: settings)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let preview = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CompressionError.renderFailed }
        try Task.checkCancellation()
        return IDPhotoResult(data: data, image: preview, editorImage: image, settings: settings, cropRect: rect)
    }
}

enum IDPhotoService {
    private static func bitmap(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CompressionError.renderFailed }
        context.interpolationQuality = .high
        return context
    }
    static func rotate(_ image: CGImage, quarterTurns: Int) throws -> CGImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let width = turns % 2 == 0 ? image.width : image.height
        let height = turns % 2 == 0 ? image.height : image.width
        let context = try bitmap(width: width, height: height)
        switch turns {
        case 1: context.translateBy(x: 0, y: CGFloat(height)); context.rotate(by: -.pi / 2)
        case 2: context.translateBy(x: CGFloat(width), y: CGFloat(height)); context.rotate(by: .pi)
        default: context.translateBy(x: CGFloat(width), y: 0); context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw CompressionError.renderFailed }
        return result
    }
    static func maskImage(_ buffer: CVPixelBuffer) throws -> CGImage {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8 else { throw CompressionError.renderFailed }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        guard let address = CVPixelBufferGetBaseAddress(buffer),
              let provider = CGDataProvider(data: Data(bytes: address, count: row * height) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: row,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw CompressionError.renderFailed }
        return image
    }
    static func composite(image: CGImage, mask: CGImage, color: CGColor) throws -> CGImage {
        let context = try bitmap(width: image.width, height: image.height)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(color); context.fill(rect)
        context.saveGState()
        // 灰度图中白色保留人像、黑色替换背景；保持连续 alpha，保留发丝过渡。
        context.clip(to: rect, mask: mask)
        context.draw(image, in: rect)
        context.restoreGState()
        guard let result = context.makeImage() else { throw CompressionError.renderFailed }
        return result
    }
    static func crop(image: CGImage, rect: CGRect, output: CGSize) throws -> CGImage {
        guard [rect.minX, rect.minY, rect.width, rect.height, output.width, output.height].allSatisfy({ $0.isFinite }),
              rect.width > 0, rect.height > 0, rect.minX >= -0.01, rect.minY >= -0.01,
              rect.maxX <= Double(image.width) + 0.01, rect.maxY <= Double(image.height) + 0.01,
              output.width >= 1, output.height >= 1, output.width * output.height <= 6_000_000 else {
            throw CompressionError.invalidDimensions
        }
        let context = try bitmap(width: Int(output.width), height: Int(output.height))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(origin: .zero, size: output))
        let sx = output.width / rect.width, sy = output.height / rect.height
        let bottom = Double(image.height) - rect.maxY
        context.draw(image, in: CGRect(x: -rect.minX * sx, y: -bottom * sy,
                                      width: Double(image.width) * sx, height: Double(image.height) * sy))
        guard let result = context.makeImage() else { throw CompressionError.renderFailed }
        return result
    }
    static func encode(_ image: CGImage, settings: IDPhotoSettings) throws -> Data {
        try settings.validate()
        func encoded(_ quality: Double) throws -> Data {
            try Task.checkCancellation()
            let data = NSMutableData()
            let type: UTType = settings.format == .jpeg ? .jpeg : .png
            guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                throw CompressionError.cannotCreateOutput
            }
            var properties: [CFString: Any] = [kCGImagePropertyOrientation: 1,
                kCGImagePropertyDPIWidth: settings.dpi, kCGImagePropertyDPIHeight: settings.dpi]
            if settings.format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(dest, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw CompressionError.writeFailed }
            return data as Data
        }
        let high = try encoded(0.95)
        guard settings.limitSize else { return high }
        let limit = settings.maximumKB * 1024
        if high.count <= limit { return high }
        var lowQuality = 0.1, highQuality = 0.95
        var best = try encoded(lowQuality)
        guard best.count <= limit else {
            throw IDPhotoError.message("在保持 \(image.width)×\(image.height) 像素及最低质量的情况下，无法小于 \(settings.maximumKB) KB。请提高上限或按提交要求调整尺寸。")
        }
        for _ in 0..<9 {
            let quality = (lowQuality + highQuality) / 2
            let data = try encoded(quality)
            if data.count <= limit { best = data; lowQuality = quality } else { highQuality = quality }
        }
        return best
    }
    /// PDF 使用精确毫米尺寸，单张位图不因排版再次有损压缩。
    static func layout(photoMM: CGSize, paper: IDPhotoPaper) throws -> [CGRect] {
        let page = paper.millimeters
        let margin = 5.0, gap = 2.0
        guard photoMM.width.isFinite, photoMM.height.isFinite, (10...100).contains(photoMM.width), (10...100).contains(photoMM.height) else {
            throw CompressionError.invalidDimensions
        }
        let columns = Int(floor((page.width - margin * 2 + gap) / (photoMM.width + gap)))
        let rows = Int(floor((page.height - margin * 2 + gap) / (photoMM.height + gap)))
        guard columns > 0, rows > 0, columns * rows <= 600 else { throw IDPhotoError.message("当前照片尺寸放不进所选纸张，请更换纸张或缩小尺寸。") }
        let left = (page.width - Double(columns) * photoMM.width - Double(columns - 1) * gap) / 2
        let bottom = (page.height - Double(rows) * photoMM.height - Double(rows - 1) * gap) / 2
        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                CGRect(x: left + Double(column) * (photoMM.width + gap),
                       y: bottom + Double(row) * (photoMM.height + gap), width: photoMM.width, height: photoMM.height)
            }
        }
    }
    static func printPreview(result: IDPhotoResult, paper: IDPhotoPaper, cropMarks: Bool) throws -> IDPhotoPrintPreview {
        try Task.checkCancellation()
        let positions = try layout(photoMM: result.settings.millimeters, paper: paper)
        let data = try printPDF(result: result, paper: paper, cropMarks: cropMarks)
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), let page = document.page(at: 1) else {
            throw IDPhotoError.message("无法读取打印排版预览，请重新生成。")
        }
        let bounds = page.getBoxRect(.mediaBox)
        // 固定最长边 1800 px，足够放大查看且不随 600 DPI 排版无限增加内存。
        let scale = 1800 / max(bounds.width, bounds.height)
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw IDPhotoError.message("无法生成打印排版预览，请重试。")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // 本服务生成的页面原点为零、无旋转；显式按 MediaBox 缩放到整张栅格。
        context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        try Task.checkCancellation()
        context.drawPDFPage(page)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw IDPhotoError.message("无法生成打印排版预览，请重试。") }
        return IDPhotoPrintPreview(data: data, image: image, settings: result.settings, paper: paper,
                                   cropMarks: cropMarks, photoCount: positions.count)
    }

    static func printPDF(result: IDPhotoResult, paper: IDPhotoPaper, cropMarks: Bool) throws -> Data {
        let positions = try layout(photoMM: result.settings.millimeters, paper: paper)
        let pointsPerMM = 72.0 / 25.4
        var box = CGRect(origin: .zero, size: CGSize(width: paper.millimeters.width * pointsPerMM,
                                                    height: paper.millimeters.height * pointsPerMM))
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw CompressionError.cannotCreateOutput
        }
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
        context.interpolationQuality = .high
        for mm in positions {
            try Task.checkCancellation()
            let r = CGRect(x: mm.minX * pointsPerMM, y: mm.minY * pointsPerMM,
                           width: mm.width * pointsPerMM, height: mm.height * pointsPerMM)
            context.draw(result.image, in: r)
            if cropMarks {
                context.setStrokeColor(CGColor(gray: 0.4, alpha: 1)); context.setLineWidth(0.25)
                let length = 0.6 * pointsPerMM, offset = 0.2 * pointsPerMM
                for x in [r.minX, r.maxX] {
                    for y in [r.minY, r.maxY] {
                        let sx = x == r.minX ? -1.0 : 1.0, sy = y == r.minY ? -1.0 : 1.0
                        context.move(to: CGPoint(x: x + sx * offset, y: y))
                        context.addLine(to: CGPoint(x: x + sx * (offset + length), y: y))
                        context.move(to: CGPoint(x: x, y: y + sy * offset))
                        context.addLine(to: CGPoint(x: x, y: y + sy * (offset + length)))
                    }
                }
                context.strokePath()
            }
        }
        context.endPDFPage(); context.closePDF()
        return data as Data
    }
}
