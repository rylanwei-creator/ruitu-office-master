import XCTest
import AppKit
import ImageIO
import CoreImage
@testable import RuiTuOfficeMaster

final class CleanupTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ruitu-cleanup-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private let target = CleanupRegion(rect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
    private let sample = CGPoint(x: 0.7, y: 0.2)
    private func image(width: Int = 200, height: Int = 160) -> CGImage {
        let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        c.setFillColor(CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height) * 0.5))
        c.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: CGFloat(width) * 0.1, y: CGFloat(height) * 0.7, width: CGFloat(width) * 0.2, height: CGFloat(height) * 0.2))
        return c.makeImage()!
    }
    private func bytes(_ image: CGImage) -> [UInt8] {
        let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        let data = bytes(image), index = (y * image.width + x) * 4
        return Array(data[index..<(index + 4)])
    }
    private func file(_ name: String = "source.png", width: Int = 200, height: Int = 160) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ImageCodec.encode(image(width: width, height: height), type: .png, quality: 1).write(to: url)
        return url
    }
    func testCanvasLetterboxMappingAndReverseSelection() throws {
        let rect = CleanupCanvasGeometry.imageRect(image: CGSize(width: 100, height: 200), canvas: CGSize(width: 400, height: 300))
        XCTAssertEqual(rect, CGRect(x: 125, y: 0, width: 150, height: 300))
        XCTAssertFalse(rect.contains(CGPoint(x: 50, y: 100)))
        XCTAssertEqual(CleanupCanvasGeometry.normalized(CGPoint(x: 200, y: 150), in: rect), CGPoint(x: 0.5, y: 0.5))
        let selection = try XCTUnwrap(CleanupRegion.selection(from: CGPoint(x: 0.8, y: 0.7), to: CGPoint(x: -1, y: 0.1)))
        XCTAssertEqual(selection.rect.minX, 0); XCTAssertEqual(selection.rect.width, 0.8)
        XCTAssertEqual(selection.rect.height, 0.6, accuracy: 0.00001)
        XCTAssertNil(CleanupRegion.selection(from: .zero, to: .zero))
    }
    func testInvalidRegionsSamplesAndFeatherAreRejected() {
        let source = image()
        for rect in [CGRect(x: -0.1, y: 0, width: 0.1, height: 0.1), CGRect(x: 0.9, y: 0, width: 0.2, height: 0.1), CGRect(x: 0, y: 0, width: 0, height: 0.1), CGRect(x: CGFloat.nan, y: 0, width: 0.1, height: 0.1)] {
            XCTAssertThrowsError(try ImageCleanupService.surrounding(source, region: CleanupRegion(rect: rect)))
        }
        for center in [CGPoint(x: 0, y: 0), CGPoint(x: 0.2, y: 0.2), CGPoint(x: CGFloat.nan, y: 0.5)] {
            XCTAssertThrowsError(try ImageCleanupService.sample(source, region: target, center: center, feather: 0))
        }
        for feather in [-1.0, 21, .nan] { XCTAssertThrowsError(try ImageCleanupService.sample(source, region: target, center: sample, feather: feather)) }
        XCTAssertThrowsError(try ImageCleanupService.surrounding(source, region: CleanupRegion(rect: CGRect(x: 0, y: 0, width: 1, height: 1))))
    }
    func testSurroundingRepairTargetsTopLeftAndLeavesOutsideUnchanged() throws {
        let source = image(), result = try ImageCleanupService.surrounding(source, region: target)
        XCTAssertEqual(pixel(source, x: 40, y: 32), [255, 0, 0, 255])
        XCTAssertEqual(pixel(result, x: 40, y: 32), [0, 0, 255, 255])
        let before = bytes(source), after = bytes(result), rect = try target.pixels(in: CGSize(width: 200, height: 160))
        for y in 0..<160 { for x in 0..<200 where !rect.contains(CGPoint(x: x, y: y)) {
            let i = (y * 200 + x) * 4
            XCTAssertEqual(Array(after[i..<i+4]), Array(before[i..<i+4]))
        } }
    }
    func testSampleRepairTopLeftCoordinatesFeatherAndOutsidePreservation() throws {
        try requireImageRenderer()
        let source = image(), result = try ImageCleanupService.sample(source, region: target, center: sample, feather: 0)
        XCTAssertEqual(pixel(result, x: 40, y: 32), [0, 0, 255, 255])
        XCTAssertEqual(pixel(result, x: 40, y: 130), [0, 255, 0, 255])
        let smooth = try ImageCleanupService.sample(source, region: target, center: sample, feather: 4)
        XCTAssertLessThan(pixel(smooth, x: 40, y: 32)[0], 3)
        XCTAssertEqual(pixel(smooth, x: 5, y: 5), pixel(source, x: 5, y: 5))
    }
    func testManualEraseAndPNGExportPreserveAlphaAndDimensions() throws {
        let result = try ImageCleanupService.erase(image(), region: target)
        XCTAssertEqual(pixel(result, x: 40, y: 32)[3], 0)
        XCTAssertEqual(pixel(result, x: 40, y: 130)[3], 255)
        let data = try ImageCodec.encode(result, type: .png, quality: 1)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 200); XCTAssertEqual(decoded.height, 160)
        XCTAssertEqual(pixel(decoded, x: 40, y: 32)[3], 0)
    }
    func testLargeImportIsBoundedAndReported() throws {
        let asset = try ImageCleanupService.prepare(file(width: 4200, height: 420))
        XCTAssertEqual(asset.originalSize, CGSize(width: 4200, height: 420)); XCTAssertTrue(asset.isDownscaled)
        XCTAssertEqual(asset.image.width, 4096); XCTAssertEqual(asset.image.height, 410)
    }
    @MainActor private func ready(_ vm: ImageCleanupViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while vm.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(vm.busy)
    }
    @MainActor func testImageEditsUndoResetCancelAndSourcePreservation() async throws {
        let url = try file(), original = try Data(contentsOf: url), vm = ImageCleanupViewModel(tool: .watermark)
        vm.load(url); try await ready(vm)
        XCTAssertFalse(vm.canSave); vm.region = target; vm.process(); try await ready(vm)
        XCTAssertNil(vm.errorMessage); XCTAssertTrue(vm.canSave)
        XCTAssertEqual(pixel(try XCTUnwrap(vm.workingImage), x: 40, y: 32)[0], 0)
        vm.undo(); XCTAssertEqual(pixel(try XCTUnwrap(vm.workingImage), x: 40, y: 32)[0], 255)
        vm.process(); try await ready(vm); vm.restoreOriginal(); XCTAssertFalse(vm.hasResult); XCTAssertFalse(vm.canSave)
        vm.load(url); vm.clear(); try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(vm.workingImage); XCTAssertNil(vm.sourceURL); XCTAssertFalse(vm.hasResult)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testInvalidSampleDoesNotReplacePreviousResult() async throws {
        let vm = ImageCleanupViewModel(tool: .watermark); vm.load(try file()); try await ready(vm)
        vm.region = target; vm.process(); try await ready(vm)
        let result = try XCTUnwrap(vm.workingImage)
        vm.repairMethod = .sample; vm.sampleCenter = CGPoint(x: 0.2, y: 0.2); vm.process(); try await ready(vm)
        XCTAssertNotNil(vm.errorMessage); XCTAssertEqual(bytes(try XCTUnwrap(vm.workingImage)), bytes(result)); XCTAssertTrue(vm.hasResult)
    }
    func testNewToolsAreDiscoverable() {
        XCTAssertEqual(ToolCatalog.search("抠图").map(\.item), [.cutout])
        XCTAssertEqual(Set(ToolCatalog.search("去水印").map(\.item)), Set([.imageWatermark]))
    }
    // Native Vision smoke test uses a project-owned QA portrait when available; never treats failure as success.
    func testNativeForegroundCutoutProducesTransparency() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = project.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa-fixtures/人像换底验收-NASA.jpg")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Native foreground smoke fixture is not part of portable source tests.") }
        let asset = try ImageCleanupService.prepare(fixture)
        let result: CutoutResult
        do { result = try ImageCleanupService.cutout(asset.image) }
        catch {
            if error.localizedDescription.contains("Espresso") && error.localizedDescription.contains("entitlements") {
                throw XCTSkip("Restricted command-line process cannot create Vision inference context; native app validation is required.")
            }
            throw error
        }
        XCTAssertGreaterThan(result.subjects, 0); XCTAssertEqual(result.image.width, asset.image.width); XCTAssertEqual(result.image.height, asset.image.height)
        let data = bytes(result.image), alphas = stride(from: 3, to: data.count, by: 4).map { data[$0] }
        XCTAssertTrue(alphas.contains { $0 < 10 }); XCTAssertTrue(alphas.contains { $0 > 240 })
        try ImageCodec.encode(result.image, type: .png, quality: 1).write(to: fixture.deletingLastPathComponent().appendingPathComponent("抠图验收结果.png"))
    }

    private func requireImageRenderer() throws {
        let plain = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        guard CIContext(options: [.useSoftwareRenderer: true]).createCGImage(plain, from: plain.extent) != nil else {
            throw XCTSkip("System Core Image rendering is unavailable in this process; native app validation is required.")
        }
    }
}
