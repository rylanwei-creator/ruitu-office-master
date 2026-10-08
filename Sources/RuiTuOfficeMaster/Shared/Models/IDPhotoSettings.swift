import Foundation
import CoreGraphics

/// 名称仅用于常用尺寸快捷选择，实际尺寸以毫米和导出像素为准。
enum IDPhotoPreset: String, CaseIterable, Sendable {
    case one = "一寸 · 25×35 mm"
    case smallTwo = "小二寸 · 33×48 mm"
    case two = "二寸 · 35×49 mm"
    case custom = "自定义"
    var millimeters: CGSize? {
        switch self {
        case .one: CGSize(width: 25, height: 35)
        case .smallTwo: CGSize(width: 33, height: 48)
        case .two: CGSize(width: 35, height: 49)
        case .custom: nil
        }
    }
}
enum IDPhotoBackground: String, CaseIterable, Sendable {
    case original = "保留原背景", white = "白色", blue = "蓝色", red = "红色", custom = "自选颜色"
    var rgb: (Double, Double, Double)? {
        switch self {
        case .original, .custom: nil
        case .white: (1, 1, 1)
        case .blue: (0.26, 0.56, 0.85)
        case .red: (0.82, 0.09, 0.11)
        }
    }
}
enum IDPhotoFormat: String, CaseIterable, Sendable { case jpeg = "JPG", png = "PNG" }
enum IDPhotoPaper: String, CaseIterable, Sendable {
    case sixInch = "6 寸相纸（4×6 英寸）", a4 = "A4"
    var millimeters: CGSize {
        switch self {
        case .sixInch: CGSize(width: 152.4, height: 101.6)
        case .a4: CGSize(width: 210, height: 297)
        }
    }
}
struct IDPhotoSettings: Equatable, Sendable {
    var preset: IDPhotoPreset = .one
    var widthMM: Double = 25
    var heightMM: Double = 35
    var dpi = 300
    var background: IDPhotoBackground = .original
    var red = 1.0, green = 1.0, blue = 1.0
    var format: IDPhotoFormat = .jpeg
    var limitSize = false
    var maximumKB = 200
    var crop = IDPhotoCrop()
    var millimeters: CGSize { preset.millimeters ?? CGSize(width: widthMM, height: heightMM) }
    var pixelSize: CGSize {
        CGSize(width: (millimeters.width / 25.4 * Double(dpi)).rounded(),
               height: (millimeters.height / 25.4 * Double(dpi)).rounded())
    }
    var backgroundColor: CGColor? {
        guard background != .original else { return nil }
        let rgb = background.rgb ?? (red, green, blue)
        return CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
    func validate() throws {
        let mm = millimeters
        guard mm.width.isFinite, mm.height.isFinite,
              (10...100).contains(mm.width), (10...100).contains(mm.height),
              (72...600).contains(dpi),
              [red, green, blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              crop.zoom.isFinite, (1...4).contains(crop.zoom),
              crop.x.isFinite, crop.y.isFinite, (-1...1).contains(crop.x), (-1...1).contains(crop.y)
        else { throw IDPhotoError.message("尺寸须为 10–100 mm，DPI 须为 72–600；裁切参数无效时请重置构图。") }
        if limitSize {
            guard format == .jpeg else { throw IDPhotoError.message("文件大小上限仅支持 JPG；PNG 为无损格式。") }
            guard (10...5000).contains(maximumKB) else { throw IDPhotoError.message("大小上限须为 10–5000 KB（1 KB = 1024 字节）。") }
        }
    }
}
/// 左上为原点。x/y 表示可移动范围内的位置，-1 为左/上，1 为右/下。
struct IDPhotoCrop: Equatable, Sendable {
    var zoom: Double = 1
    var x: Double = 0
    var y: Double = 0
    func rect(in image: CGSize, aspect: CGFloat) -> CGRect {
        guard image.width > 0, image.height > 0, aspect.isFinite, aspect > 0 else { return .zero }
        let z = min(4, max(1, zoom.isFinite ? zoom : 1))
        let width = min(image.width, image.height * aspect) / z
        let height = width / aspect
        let px = min(1, max(-1, x.isFinite ? x : 0))
        let py = min(1, max(-1, y.isFinite ? y : 0))
        return CGRect(x: (image.width - width) * (px + 1) / 2,
                      y: (image.height - height) * (py + 1) / 2, width: width, height: height)
    }
    static func framing(face: CGRect, image: CGSize, aspect: CGFloat) -> Self {
        // Vision 人脸框不包含完整头发，额外留出头顶与肩部空间；只是起始构图。
        let maxWidth = min(image.width, image.height * aspect)
        let width = min(maxWidth, max(maxWidth / 4, face.width * 2.5))
        let height = width / aspect
        let originX = face.midX - width / 2
        let originY = face.midY - height * 0.40
        return Self(zoom: maxWidth / width,
                    x: image.width > width ? min(1, max(-1, 2 * originX / (image.width - width) - 1)) : 0,
                    y: image.height > height ? min(1, max(-1, 2 * originY / (image.height - height) - 1)) : 0)
    }
}
enum IDPhotoError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
