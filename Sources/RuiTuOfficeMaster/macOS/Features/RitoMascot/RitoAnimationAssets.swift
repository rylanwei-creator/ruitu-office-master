#if os(macOS)
import AppKit
import Observation

/// The original body is immutable. Only calibrated eye/mouth rectangles receive expression sprites.
/// Frames share a 1254-square source canvas (coordinates calibrated directly in the original 1254-pixel canvas) and are built once, never in the animation tick.
@MainActor enum RitoAnimationAssets {
    @MainActor @Observable final class Cache {
        var frames: [String: NSImage] = [:]
        @ObservationIgnored var work: Task<FramePack, Never>?
    }
    struct FramePack: @unchecked Sendable { let images: [String: NSImage] }
    private struct Input: @unchecked Sendable { let base: CGImage; let sprites: CGImage }
    private static let cache = Cache()
    static let original = load("RitoMascot")
    static let sheet = load("RitoExpressions")
    static var frames: [String: NSImage] { cache.frames }
    static func prepare() async {
        if !cache.frames.isEmpty { return }
        if cache.work == nil {
            guard let original, let base = original.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let sheet, let sprites = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let input = Input(base: base, sprites: sprites)
            cache.work = Task.detached(priority: .utility) { FramePack(images: makeFrames(input)) }
        }
        guard let work = cache.work else { return }
        let result = await work.value
        cache.frames = result.images; cache.work = nil
    }
    static func image(mouth: Int, eyes: Int) -> NSImage? { frames["\(mouth)-\(eyes)"] ?? original }
    static func load(_ name: String) -> NSImage? {
        guard let url = AppResources.bundle.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
    nonisolated private static func makeFrames(_ input: Input) -> [String: NSImage] {
        let base = input.base, sprites = input.sprites
        let width = base.width, height = base.height
        let cellWidth = sprites.width / 2, cellHeight = sprites.height / 4
        func cell(_ column: Int, _ row: Int) -> CGImage? {
            guard let image = sprites.cropping(to: CGRect(x: column * cellWidth, y: row * cellHeight, width: cellWidth, height: cellHeight)) else { return nil }
            let bitmap = NSBitmapImageRep(cgImage: image)
            let alphaIndex = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : bitmap.samplesPerPixel - 1
            let pixels = bitmap.bitmapData!
            var x0 = image.width, y0 = image.height, x1 = 0, y1 = 0
            for y in 0..<image.height { for x in 0..<image.width {
                if pixels[y * bitmap.bytesPerRow + x * bitmap.samplesPerPixel + alphaIndex] > 38 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
            } }
            guard x1 >= x0, y1 >= y0 else { return nil }
            return image.cropping(to: CGRect(x: x0, y: y0, width: x1-x0+1, height: y1-y0+1))
        }
        let half = cell(1, 0), open = cell(0, 1)
        let blink = cell(1, 2), thinking = cell(0, 3), puzzled = cell(1, 3)
        // Image coordinates are top-down; Core Graphics destination coordinates are bottom-up.
        func sourceRect(_ rect: CGRect) -> CGRect {
            let scale = CGFloat(width) / 1254
            return CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        }
        func bottomRect(_ rect: CGRect) -> CGRect {
            let rect = sourceRect(rect)
            return CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
        }
        // Erase only original eye ink; retain blush and the textured white face.
        let face = NSBitmapImageRep(cgImage: base)
        let eyeMasks: [CGPath] = [503.0, 743.0].map { x in
            let rect = sourceRect(CGRect(x: x - 5, y: 719, width: 72, height: 140))
            let path = CGMutablePath()
            for y in Int(rect.minY)..<Int(rect.maxY) {
                var run: Int?
                for px in Int(rect.minX)...Int(rect.maxX) {
                    let ink: Bool
                    if px < Int(rect.maxX), let color = face.colorAt(x: px, y: y)?.usingColorSpace(.deviceRGB) {
                        ink = color.alphaComponent > 0.1 && max(color.redComponent, color.greenComponent, color.blueComponent) < 0.82
                    } else { ink = false }
                    if ink && run == nil { run = px }
                    if !ink, let start = run {
                        path.addRect(CGRect(x: start, y: height - y - 1, width: px - start, height: 1))
                        run = nil
                    }
                }
            }
            return path
        }
        var result: [String: NSImage] = [:]
        for mouth in 0...2 { for eyes in 0...3 {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.interpolationQuality = .none
            context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Extend adjacent clean face pixels; no body pixel or cheek is erased.
            func clean(_ rect: CGRect, from sample: CGRect) {
                if let clean = base.cropping(to: sourceRect(sample)) { context.draw(clean, in: bottomRect(rect)) }
            }
            if mouth > 0, let sprite = mouth == 1 ? half : open {
                clean(CGRect(x: 596, y: 832, width: 112, height: 58), from: CGRect(x: 596, y: 824, width: 112, height: 1))
                context.draw(sprite, in: bottomRect(CGRect(x: 606, y: mouth == 1 ? 841 : 833, width: 92, height: mouth == 1 ? 43 : 55)))
            }
            if eyes > 0, let pair = eyes == 1 ? blink : (eyes == 2 ? thinking : puzzled) {
                for (eye, x) in [503.0, 743.0].enumerated() {
                    context.saveGState()
                    context.addPath(eyeMasks[eye]); context.clip()
                    clean(CGRect(x: x-5, y: 719, width: 72, height: 140), from: CGRect(x: eye == 0 ? 580 : 720, y: 719, width: 1, height: 140))
                    context.restoreGState()
                    let halfWidth = pair.width / 2
                    if let sprite = pair.cropping(to: CGRect(x: eye * halfWidth, y: 0, width: halfWidth, height: pair.height)) {
                        // Trim horizontal gap independently, so the original eye spacing stays fixed.
                        let rep = NSBitmapImageRep(cgImage: sprite)
                        let pixels = rep.bitmapData!
                        let alphaIndex = rep.bitmapFormat.contains(.alphaFirst) ? 0 : rep.samplesPerPixel - 1
                        var left = sprite.width, right = 0
                        for y in 0..<sprite.height { for x in 0..<sprite.width where pixels[y * rep.bytesPerRow + x * rep.samplesPerPixel + alphaIndex] > 38 { left = min(left, x); right = max(right, x) } }
                        if let trimmed = sprite.cropping(to: CGRect(x: left, y: 0, width: max(1, right-left+1), height: sprite.height)) {
                            context.draw(trimmed, in: bottomRect(CGRect(x: x, y: eyes == 1 ? 784 : 725, width: 61, height: eyes == 1 ? 18 : 131)))
                        }
                    }
                }
            }
            if let image = context.makeImage() { result["\(mouth)-\(eyes)"] = NSImage(cgImage: image, size: NSSize(width: width, height: height)) }
        } }
        return result
    }
}
#endif
