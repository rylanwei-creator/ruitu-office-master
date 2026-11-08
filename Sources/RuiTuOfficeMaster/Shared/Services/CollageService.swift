import Foundation
import CoreGraphics
import CoreText
import UniformTypeIdentifiers

/// Offline-only composition. Input decoding, filters and export are called on a worker task.
enum CollageService {
    static let maximumPhotos = 12
    static let maximumPixels: CGFloat = 24_000_000
    static let maximumSide: CGFloat = 16384

    static func prepare(_ url: URL) throws -> CollagePhoto {
        try Task.checkCancellation()
        guard url.isFileURL else { throw CollageError.message("请选择本机图片。") }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try ImageCodec.validateStaticImage(at: url)
        let size = try ImageCodec.dimensions(at: url)
        guard size.width > 0, size.height > 0 else { throw CollageError.message("图片尺寸无效。") }
        let thumbnail = try ImageCodec.load(at: url, size: CGSize(width: 180, height: 180))
        return CollagePhoto(url: url, size: size, thumbnail: thumbnail)
    }

    static func geometry(sizes: [CGSize], settings: CollageSettings) throws -> CollageGeometry {
        guard !sizes.isEmpty, sizes.count <= maximumPhotos else { throw CollageError.message("请添加 1–\(maximumPhotos) 张图片。") }
        guard sizes.allSatisfy({ $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }),
              settings.resolution.isFinite, (600...4096).contains(settings.resolution),
              settings.spacing.isFinite, (0...80).contains(settings.spacing),
              settings.margin.isFinite, (0...120).contains(settings.margin) else {
            throw CollageError.message("画布尺寸或图片参数无效。")
        }
        let width = CGFloat(settings.resolution), gap = CGFloat(settings.spacing), margin = CGFloat(settings.margin)
        var size: CGSize; var cells: [CGRect]
        if settings.mode == .grid {
            size = CGSize(width: width, height: (width / settings.ratio.value).rounded())
            let inner = CGRect(x: margin, y: margin, width: size.width - margin * 2, height: size.height - margin * 2)
            cells = settings.template.cells(count: sizes.count).map { cell in
                // Half a gap at shared edges, no gap at the outer border.
                let left = cell.minX > 0.0001 ? gap/2 : 0
                let top = cell.minY > 0.0001 ? gap/2 : 0
                let right = cell.maxX < 0.9999 ? gap/2 : 0
                let bottom = cell.maxY < 0.9999 ? gap/2 : 0
                return CGRect(x: inner.minX + cell.minX * inner.width + left,
                              y: inner.minY + cell.minY * inner.height + top,
                              width: cell.width * inner.width - left - right,
                              height: cell.height * inner.height - top - bottom)
            }
        } else {
            var cursor = margin
            cells = sizes.map { source in
                let cellSize = settings.mode == .vertical
                    ? CGSize(width: width, height: width * source.height / source.width)
                    : CGSize(width: width * source.width / source.height, height: width)
                let cell = CGRect(x: settings.mode == .vertical ? margin : cursor,
                                  y: settings.mode == .vertical ? cursor : margin,
                                  width: cellSize.width, height: cellSize.height)
                cursor += (settings.mode == .vertical ? cellSize.height : cellSize.width) + gap
                return cell
            }
            size = settings.mode == .vertical
                ? CGSize(width: width + 2*margin, height: cursor - gap + margin)
                : CGSize(width: cursor - gap + margin, height: width + 2*margin)
        }
        guard cells.allSatisfy({ $0.size.width >= 1 && $0.size.height >= 1 }), size.width.isFinite, size.height.isFinite else {
            throw CollageError.message("当前间距过大，请减小间距、边距或换一种布局。")
        }
        let factor = min(1, maximumSide/max(size.width,size.height), sqrt(maximumPixels / (size.width*size.height)))
        if factor < 1 {
            size = CGSize(width: floor(size.width*factor), height: floor(size.height*factor))
            cells = cells.map { CGRect(x: $0.minX*factor, y: $0.minY*factor, width: $0.width*factor, height: $0.height*factor) }
        }
        guard size.width >= 1, size.height >= 1, cells.allSatisfy({ $0.size.width >= 1 && $0.size.height >= 1 }) else {
            throw CollageError.message("图片比例过于狭长，请减少图片数量或分批拼接。")
        }
        return CollageGeometry(size: size, cells: cells, reduced: factor < 1)
    }

    static func render(photos: [CollagePhoto], settings: CollageSettings, previewMaximum: CGFloat? = nil,
                       progress: @Sendable (Double) -> Void = { _ in }) throws -> CGImage {
        try Task.checkCancellation()
        let geometry = try geometry(sizes: photos.map(\.size), settings: settings)
        let scale = previewMaximum.map { min(1, $0/max(geometry.size.width,geometry.size.height)) } ?? 1
        let width = max(1, Int((geometry.size.width*scale).rounded()))
        let height = max(1, Int((geometry.size.height*scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CollageError.message("无法分配拼图画布，请降低输出尺寸。")
        }
        let (r,g,b,a) = settings.background.rgba
        context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: a))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, photo) in photos.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let access = photo.url.startAccessingSecurityScopedResource()
                defer { if access { photo.url.stopAccessingSecurityScopedResource() } }
                // A changed source must not silently change the crop proportions.
                try ImageCodec.validateStaticImage(at: photo.url)
                guard try ImageCodec.dimensions(at: photo.url) == photo.size else { throw CollageError.message("图片「\(photo.url.lastPathComponent)」已变化，请移除后重新添加。") }
                let topRect = geometry.cells[index]
                let rect = CGRect(x: topRect.minX*scale, y: CGFloat(height)-topRect.maxY*scale,
                                  width: topRect.width*scale, height: topRect.height*scale)
                let fit = settings.mode == .grid && settings.fitImages
                let base = fit ? min(rect.width/photo.size.width,rect.height/photo.size.height)
                               : max(rect.width/photo.size.width,rect.height/photo.size.height)
                let zoom = settings.mode == .grid && !fit ? min(3,max(1,photo.zoom)) : 1
                let drawn = CGSize(width: photo.size.width*base*zoom, height: photo.size.height*base*zoom)
                let decode = CGSize(width: min(4096,max(rect.width,drawn.width)), height: min(4096,max(rect.height,drawn.height)))
                let image = try adjusted(ImageCodec.load(at: photo.url, size: decode), settings: settings)
                let panX = fit || settings.mode != .grid ? 0 : min(1,max(-1,photo.panX))
                let panY = fit || settings.mode != .grid ? 0 : min(1,max(-1,photo.panY))
                let drawRect = CGRect(x: rect.midX-drawn.width/2 + panX*max(0,drawn.width-rect.width)/2,
                                      y: rect.midY-drawn.height/2 - panY*max(0,drawn.height-rect.height)/2,
                                      width: drawn.width, height: drawn.height)
                context.saveGState(); context.clip(to: rect); context.draw(image, in: drawRect); context.restoreGState()
            }
            progress(Double(index+1)/Double(photos.count))
        }
        let commonSide: CGFloat
        switch settings.mode {
        case .grid: commonSide = geometry.size.width
        case .vertical: commonSide = geometry.cells[0].width
        case .horizontal: commonSide = geometry.cells[0].height
        }
        drawCaption(in: context, width: CGFloat(width), height: CGFloat(height), settings: settings, scale: scale * commonSide / CGFloat(settings.resolution))
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw CollageError.message("生成拼图失败。") }
        return image
    }

    /// Deterministic sRGB filter, no GPU or network dependency. Background and captions stay unchanged.
    private static func adjusted(_ image: CGImage, settings: CollageSettings) throws -> CGImage {
        guard settings.filter != .original || settings.brightness != 0 || settings.contrast != 1 || settings.saturation != 1 else { return image }
        guard (-0.5...0.5).contains(settings.brightness), (0.5...1.5).contains(settings.contrast), (0...2).contains(settings.saturation),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width*4,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = c.data?.assumingMemoryBound(to: UInt8.self) else { throw CollageError.message("图片调节参数无效。") }
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        for y in 0..<image.height {
            if y.isMultiple(of: 64) { try Task.checkCancellation() }
            for x in 0..<image.width {
                let i = (y*image.width+x)*4
                let alpha = Double(data[i+3])/255
                guard alpha > 0 else { continue }
                let red = Double(data[i])/255/alpha, green = Double(data[i+1])/255/alpha, blue = Double(data[i+2])/255/alpha
                let luma = red*0.2126 + green*0.7152 + blue*0.0722
                let saturation = settings.filter == .mono ? 0 : settings.saturation
                let bias = 0.5+settings.brightness
                var r = (luma+(red-luma)*saturation-0.5)*settings.contrast+bias
                let g = (luma+(green-luma)*saturation-0.5)*settings.contrast+bias
                var b = (luma+(blue-luma)*saturation-0.5)*settings.contrast+bias
                if settings.filter == .warm { r += 0.07; b -= 0.04 }
                if settings.filter == .cool { b += 0.07; r -= 0.04 }
                data[i] = UInt8((min(1,max(0,r))*alpha*255).rounded())
                data[i+1] = UInt8((min(1,max(0,g))*alpha*255).rounded())
                data[i+2] = UInt8((min(1,max(0,b))*alpha*255).rounded())
            }
        }
        guard let result = c.makeImage() else { throw CollageError.message("图片调节失败。") }
        return result
    }

    private static func drawCaption(in context: CGContext, width: CGFloat, height: CGFloat, settings: CollageSettings, scale: CGFloat) {
        let text = String(settings.caption.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(80))
        guard !text.isEmpty else { return }
        let fontSize = max(6,CGFloat(settings.captionSize)*scale)
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, fontSize, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 0.12, alpha: 1)
        ]))
        let textWidth = CGFloat(CTLineGetTypographicBounds(line,nil,nil,nil))
        let factor = min(1,(width*0.88)/max(1,textWidth))
        let padding = fontSize*0.45
        let boxHeight = fontSize*1.5+padding
        let y = settings.captionAtTop ? height-boxHeight-fontSize*0.5 : fontSize*0.5
        let box = CGRect(x: (width-textWidth*factor)/2-padding, y: y, width: textWidth*factor+padding*2, height: boxHeight)
        context.setFillColor(CGColor(gray: 1,alpha: 0.9))
        context.fill(box)
        context.saveGState()
        context.translateBy(x: (width-textWidth*factor)/2, y: y+padding)
        context.scaleBy(x: factor,y: factor)
        context.textMatrix = .identity; context.textPosition = .zero
        CTLineDraw(line,context); context.restoreGState()
    }

    static func export(photos: [CollagePhoto], settings: CollageSettings, to url: URL,
                       progress: @Sendable (Double) -> Void = { _ in }) throws {
        guard !photos.contains(where: { $0.url.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL }) else {
            throw CollageError.message("不能覆盖原图片，请选择另一个保存位置或文件名。")
        }
        var image = try render(photos: photos, settings: settings, progress: progress)
        if settings.format == .jpeg {
            image = try ImageCodec.render(image,size: CGSize(width: image.width,height: image.height),flattenAlpha: true)
        }
        let data = try ImageCodec.encode(image, type: settings.format == .png ? .png : .jpeg, quality: settings.jpegQuality)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
