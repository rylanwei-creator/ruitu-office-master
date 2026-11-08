import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Small on-device previews only. Original image bytes never enter chat history.
enum RitoImagePreview {
    static let byteLimit = 96 * 1024
    static func isImage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        // Common formats must not depend on Launch Services registration in test processes.
        if ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp", "avif"].contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }
    static func data(from url: URL) -> Data? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source)
    }
    static func data(from bytes: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source)
    }
    private static func thumbnail(_ source: CGImageSource) -> Data? {
        for (edge, quality) in [(480, 0.72), (320, 0.5)] {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let bytes = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), bytes.length <= byteLimit { return bytes as Data }
        }
        return nil
    }
}
