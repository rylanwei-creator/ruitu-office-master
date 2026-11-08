import CoreGraphics
protocol ImageProcessingProvider: Sendable {
    func cutout(_ image: CGImage) throws -> CutoutResult
}
struct NativeImageProcessingProvider: ImageProcessingProvider {
    func cutout(_ image: CGImage) throws -> CutoutResult { try ImageCleanupService.cutout(image) }
}
