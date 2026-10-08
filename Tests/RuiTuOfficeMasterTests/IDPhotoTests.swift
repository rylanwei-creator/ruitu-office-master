import XCTest
import ImageIO
import AppKit
import PDFKit
import UniformTypeIdentifiers
@testable import RuiTuOfficeMaster

final class IDPhotoTests: XCTestCase {
    private func image(width: Int = 700, height: Int = 900, noisy: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        if noisy {
            let data = context.data!.assumingMemoryBound(to: UInt8.self)
            var seed: UInt32 = 1729
            for i in 0..<(width * height) {
                for c in 0..<3 { seed = 1664525 &* seed &+ 1013904223; data[i * 4 + c] = UInt8(truncatingIfNeeded: seed >> 24) }
                data[i * 4 + 3] = 255
            }
        } else {
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        }
        return context.makeImage()!
    }
    private func bytes(_ image: CGImage) -> [UInt8] {
        let c = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: c.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    func testCropRemainsInsideImageAndPreservesAspectAtAllEdges() {
        for size in [CGSize(width: 900, height: 500), CGSize(width: 500, height: 900)] {
            for zoom in [1.0, 2.0, 4.0] {
                for x in [-1.0, 0, 1] {
                    for y in [-1.0, 0, 1] {
                        let rect = IDPhotoCrop(zoom: zoom, x: x, y: y).rect(in: size, aspect: 25.0 / 35)
                        XCTAssertEqual(rect.width / rect.height, 25.0 / 35, accuracy: 1e-9)
                        XCTAssertGreaterThanOrEqual(rect.minX, 0); XCTAssertGreaterThanOrEqual(rect.minY, 0)
                        XCTAssertLessThanOrEqual(rect.maxX, size.width + 1e-6); XCTAssertLessThanOrEqual(rect.maxY, size.height + 1e-6)
                    }
                }
            }
        }
    }
    func testAutoFramingUsesFaceAndStaysInBounds() {
        let size = CGSize(width: 900, height: 1200), face = CGRect(x: 510, y: 180, width: 160, height: 210)
        let crop = IDPhotoCrop.framing(face: face, image: size, aspect: 25.0 / 35)
        let rect = crop.rect(in: size, aspect: 25.0 / 35)
        XCTAssertEqual(rect.midX, face.midX, accuracy: 0.001)
        XCTAssertEqual((face.midY - rect.minY) / rect.height, 0.40, accuracy: 0.001)
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rect))
    }
    func testTopAndBottomCropMatchDisplayedCoordinateSystem() throws {
        let source = image(width: 100, height: 200)
        let top = try IDPhotoService.crop(image: source, rect: CGRect(x: 0, y: 0, width: 100, height: 80), output: CGSize(width: 100, height: 80))
        let bottom = try IDPhotoService.crop(image: source, rect: CGRect(x: 0, y: 120, width: 100, height: 80), output: CGSize(width: 100, height: 80))
        // CoreGraphics 上半部分为蓝色，下半部分为红色。
        XCTAssertGreaterThan(bytes(top)[2], 240); XCTAssertLessThan(bytes(top)[0], 10)
        XCTAssertGreaterThan(bytes(bottom)[0], 240); XCTAssertLessThan(bytes(bottom)[2], 10)
    }
    func testSolidBackgroundCompositePreservesForeground() throws {
        let source = image(width: 80, height: 100)
        func grayMask(_ byte: UInt8) -> CGImage {
            let data = Data(repeating: byte, count: 80 * 100)
            return CGImage(width: 80, height: 100, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 80,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        }
        let mask = grayMask(0)
        let result = try IDPhotoService.composite(image: source, mask: mask, color: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        let backgroundPixel = bytes(result)
        XCTAssertLessThan(backgroundPixel[0], 5); XCTAssertGreaterThan(backgroundPixel[1], 250); XCTAssertLessThan(backgroundPixel[2], 5)
        let allForeground = grayMask(255)
        let preserved = try IDPhotoService.composite(image: source, mask: allForeground, color: CGColor(gray: 1, alpha: 1))
        XCTAssertEqual(bytes(preserved), bytes(source))
    }
    func testPresetsEncodeExactPixelsDPIAndFormat() async throws {
        let source = image(), asset = IDPhotoAsset(id: UUID(), image: source, faces: [], originalSize: CGSize(width: 700, height: 900), faceDetectionFailed: false)
        let worker = IDPhotoWorker()
        for preset in [IDPhotoPreset.one, .smallTwo, .two] {
            for format in IDPhotoFormat.allCases {
                var settings = IDPhotoSettings(); settings.preset = preset; settings.format = format
                let result = try await worker.render(asset: asset, settings: settings)
                XCTAssertEqual(result.image.width, Int(settings.pixelSize.width)); XCTAssertEqual(result.image.height, Int(settings.pixelSize.height))
                let src = CGImageSourceCreateWithData(result.data as CFData, nil)!
                XCTAssertEqual(CGImageSourceGetType(src)! as String, format == .jpeg ? UTType.jpeg.identifier : UTType.png.identifier)
                let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)! as NSDictionary
                XCTAssertEqual((properties[kCGImagePropertyDPIWidth] as! NSNumber).doubleValue, 300, accuracy: 0.1)
                XCTAssertEqual((properties[kCGImagePropertyDPIHeight] as! NSNumber).doubleValue, 300, accuracy: 0.1)
                XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
                let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil)!
                XCTAssertEqual(bytes(decoded), bytes(result.image))
            }
        }
    }
    func testFileSizeLimitIsActualAndKeepsPixelDimensions() throws {
        let source = image(noisy: true)
        var settings = IDPhotoSettings(); settings.limitSize = true; settings.maximumKB = 150
        let data = try IDPhotoService.encode(source, settings: settings)
        XCTAssertLessThanOrEqual(data.count, 150 * 1024)
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil)!
        XCTAssertEqual(decoded.width, source.width); XCTAssertEqual(decoded.height, source.height)
        settings.maximumKB = 10
        XCTAssertThrowsError(try IDPhotoService.encode(source, settings: settings))
    }
    func testInvalidSettingsAndTinyLayoutNeverReachRendering() {
        var settings = IDPhotoSettings(); settings.preset = .custom
        for bad in [0.0, -1, .infinity, .nan, 1e-300, 101] {
            settings.widthMM = bad
            XCTAssertThrowsError(try settings.validate())
            XCTAssertThrowsError(try IDPhotoService.layout(photoMM: settings.millimeters, paper: .sixInch))
        }
        settings = IDPhotoSettings(); settings.crop.zoom = .nan
        XCTAssertThrowsError(try settings.validate())
        settings = IDPhotoSettings(); settings.format = .png; settings.limitSize = true
        XCTAssertThrowsError(try settings.validate())
    }
    func testNoFaceAndMultipleFacesCannotSilentlyChangeBackground() async throws {
        var settings = IDPhotoSettings(); settings.background = .white
        let image = image()
        for faces in [[], [CGRect(x: 20, y: 20, width: 50, height: 60), CGRect(x: 200, y: 20, width: 50, height: 60)]] {
            let asset = IDPhotoAsset(id: UUID(), image: image, faces: faces, originalSize: CGSize(width: 700, height: 900), faceDetectionFailed: false)
            do { _ = try await IDPhotoWorker().render(asset: asset, settings: settings); XCTFail("应拒绝自动换底") }
            catch { XCTAssertTrue(error.localizedDescription.contains("人脸")) }
        }
    }
    func testPrintLayoutUsesPhysicalDimensionsAndNonoverlappingGaps() async throws {
        let settings = IDPhotoSettings(), image = image()
        let result = try await IDPhotoWorker().render(asset: IDPhotoAsset(id: UUID(), image: image, faces: [], originalSize: CGSize(width: 700, height: 900), faceDetectionFailed: false), settings: settings)
        for paper in IDPhotoPaper.allCases {
            let positions = try IDPhotoService.layout(photoMM: settings.millimeters, paper: paper)
            XCTAssertEqual(positions.count, paper == .sixInch ? 10 : 49)
            for (i, rect) in positions.enumerated() {
                XCTAssertEqual(rect.size, settings.millimeters)
                XCTAssertGreaterThanOrEqual(rect.minX, 5); XCTAssertGreaterThanOrEqual(rect.minY, 5)
                XCTAssertLessThanOrEqual(rect.maxX, paper.millimeters.width - 5)
                XCTAssertLessThanOrEqual(rect.maxY, paper.millimeters.height - 5)
                for other in positions.dropFirst(i + 1) { XCTAssertFalse(rect.intersects(other)) }
            }
            let data = try IDPhotoService.printPDF(result: result, paper: paper, cropMarks: true)
            let pdf = try XCTUnwrap(PDFDocument(data: data)); XCTAssertEqual(pdf.pageCount, 1)
            let page = try XCTUnwrap(pdf.page(at: 0)), bounds = page.bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, paper.millimeters.width * 72 / 25.4, accuracy: 0.01)
            XCTAssertEqual(bounds.height, paper.millimeters.height * 72 / 25.4, accuracy: 0.01)
            XCTAssertNotNil(page.thumbnail(of: CGSize(width: 600, height: 600), for: .mediaBox).tiffRepresentation)
        }
    }
    func testEXIFAndQuarterTurnAreAppliedBeforeCrop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("rotated.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image(width: 200, height: 100), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let worker = IDPhotoWorker(), upright = try await worker.prepare(url: url)
        XCTAssertEqual(upright.size, CGSize(width: 100, height: 200))
        let rotated = try await worker.prepare(url: url, quarterTurns: 1)
        XCTAssertEqual(rotated.size, CGSize(width: 200, height: 100))
    }
    @MainActor func testChangingParametersInvalidatesResultAndLatestWins() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.png")
        try ImageCodec.encode(image(), type: .png, quality: 1).write(to: url)
        let model = IDPhotoViewModel(); model.load(url)
        for _ in 0..<150 where model.busy { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertNotNil(model.result); XCTAssertTrue(model.canExport)
        model.settings.preset = .two; model.refresh()
        XCTAssertNil(model.result); XCTAssertFalse(model.canExport)
        model.settings.format = .png; model.settings.crop.x = 1; model.refresh()
        for _ in 0..<150 where model.busy { try await Task.sleep(for: .milliseconds(40)) }
        XCTAssertEqual(model.result?.settings, model.settings)
        XCTAssertEqual(model.result?.image.width, 413); XCTAssertEqual(model.result?.image.height, 579)
        model.clear(); XCTAssertNil(model.result); XCTAssertNil(model.asset); XCTAssertFalse(model.canExport)
        model.load(url); model.cancel()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(model.result); XCTAssertFalse(model.busy)
    }
    func testLocalPortraitSegmentationWithExplicitFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["RUITU_IDPHOTO_FIXTURE"] else {
            throw XCTSkip("真实人像验收需显式设置 RUITU_IDPHOTO_FIXTURE；普通测试不联网、不扫描用户照片。")
        }
        let worker = IDPhotoWorker()
        let asset = try await worker.prepare(url: URL(fileURLWithPath: path))
        XCTAssertFalse(asset.faceDetectionFailed, "系统人脸检测失败")
        XCTAssertEqual(asset.faces.count, 1)
        var settings = IDPhotoSettings(); settings.background = .blue
        settings.crop = .framing(face: try XCTUnwrap(asset.faces.first), image: asset.size, aspect: 25.0 / 35)
        let blue = try await worker.render(asset: asset, settings: settings)
        XCTAssertEqual(blue.image.width, 295); XCTAssertEqual(blue.image.height, 413)
        settings.background = .white
        let white = try await worker.render(asset: asset, settings: settings)
        XCTAssertNotEqual(blue.data, white.data)
        if let directory = ProcessInfo.processInfo.environment["RUITU_IDPHOTO_QA_OUTPUT"] {
            let folder = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try blue.data.write(to: folder.appendingPathComponent("blue.jpg"))
            try white.data.write(to: folder.appendingPathComponent("white.jpg"))
            try IDPhotoService.printPDF(result: white, paper: .sixInch, cropMarks: true).write(to: folder.appendingPathComponent("print.pdf"))
        }
    }

}
