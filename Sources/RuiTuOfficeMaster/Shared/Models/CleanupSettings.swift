import Foundation
import CoreGraphics

/// 编辑区域统一使用左上原点的归一化坐标，预览缩放不改变实际处理位置。
struct CleanupRegion: Sendable, Equatable {
    var rect: CGRect
    func pixels(in size: CGSize) throws -> CGRect {
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.minX >= 0, rect.minY >= 0, rect.maxX <= 1.000001, rect.maxY <= 1.000001,
              rect.width > 0, rect.height > 0, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw CleanupError.message("请在图片内框选有效区域。")
        }
        let box = CGRect(x: floor(rect.minX * size.width), y: floor(rect.minY * size.height),
                         width: ceil(rect.maxX * size.width) - floor(rect.minX * size.width),
                         height: ceil(rect.maxY * size.height) - floor(rect.minY * size.height))
        guard box.width >= 2, box.height >= 2 else { throw CleanupError.message("框选区域太小，请重新选择。") }
        return box.intersection(CGRect(origin: .zero, size: size))
    }
    static func selection(from start: CGPoint, to end: CGPoint) -> Self? {
        let a = CGPoint(x: min(1, max(0, start.x)), y: min(1, max(0, start.y)))
        let b = CGPoint(x: min(1, max(0, end.x)), y: min(1, max(0, end.y)))
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        return rect.width >= 0.002 && rect.height >= 0.002 ? Self(rect: rect) : nil
    }
    func sampleRegion(center: CGPoint) throws -> Self {
        let result = Self(rect: CGRect(x: center.x - rect.width / 2, y: center.y - rect.height / 2,
                                      width: rect.width, height: rect.height))
        guard center.x.isFinite, center.y.isFinite, result.rect.minX >= 0, result.rect.minY >= 0,
              result.rect.maxX <= 1, result.rect.maxY <= 1 else {
            throw CleanupError.message("取样区域超出边缘，请把绿色取样框移到图像内部。")
        }
        guard !result.rect.intersects(rect) else { throw CleanupError.message("取样区域不能与水印区域重叠，请选择附近干净的背景。") }
        return result
    }
}

enum CleanupError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
enum ImageCleanupTool: Sendable { case cutout, watermark }
enum WatermarkRepairMethod: String, CaseIterable, Sendable {
    case surrounding = "周边修补"
    case sample = "取样修补"
}

struct CleanupImageAsset: Sendable {
    let image: CGImage
    let originalSize: CGSize
    var size: CGSize { CGSize(width: image.width, height: image.height) }
    var isDownscaled: Bool { originalSize.width > size.width + 1 || originalSize.height > size.height + 1 }
}
