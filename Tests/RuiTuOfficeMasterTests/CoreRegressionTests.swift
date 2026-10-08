import XCTest
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import AVFoundation
@testable import RuiTuOfficeMaster

final class CoreRegressionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuiTuTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func path(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private func fixture(_ name: String = "source.png", width: Int = 320, height: Int = 200, transparent: Bool = false) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if !transparent {
            for x in 0..<width {
                context.setFillColor(CGColor(red: CGFloat(x) / CGFloat(width), green: 0.35, blue: 0.8, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: height))
            }
        }
        let url = path(name)
        try ImageCodec.encode(context.makeImage()!, type: .png, quality: 1).write(to: url)
        return url
    }
    private func pixels(_ url: URL) throws -> [UInt8] {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func pdf(_ name: String, pages: Int = 1) throws -> URL {
        let url = path(name)
        var rect = CGRect(x: 0, y: 0, width: 300, height: 220)
        let context = CGContext(url as CFURL, mediaBox: &rect, nil)!
        for i in 1...pages {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 30, y: 140)
            let string = NSAttributedString(string: "RUITU Page \(i)", attributes: [.font: NSFont.systemFont(ofSize: 20)])
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
    func testPortraitVideoTransformUsesResizedTranslation() {
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 640, ty: 0)
        let encoded = VideoGeometry.encodedSize(source: CGSize(width: 960, height: 640), transform: rotation, resolution: .sd)
        XCTAssertEqual(encoded, CGSize(width: 480, height: 320))
        let output = VideoGeometry.outputTransform(sourceTransform: rotation, encodedSize: encoded)
        XCTAssertEqual(output.tx, 320)
        let bounds = CGRect(origin: .zero, size: encoded).applying(output).standardized
        XCTAssertEqual(bounds.origin, .zero)
        XCTAssertEqual(bounds.size, CGSize(width: 320, height: 480))
    }
    func testVideoOriginalResolutionRoundsOddPixelsWithoutUpscaling() {
        let size = VideoGeometry.encodedSize(source: CGSize(width: 1025, height: 1001), transform: .identity, resolution: .original)
        XCTAssertLessThanOrEqual(size.width, 1025); XCTAssertLessThanOrEqual(size.height, 1001)
        XCTAssertEqual(Int(size.width) % 2, 0); XCTAssertEqual(Int(size.height) % 2, 0)
        XCTAssertEqual(VideoResolution.hd.targetSize(clampedTo: .zero), .zero)
    }
    @MainActor func testImageEstimateReportsGrowthAndPendingState() {
        let vm = ImageCompressionViewModel(), input = path("image.png")
        vm.selectedImages = [input]; vm.originalSizes = [input: 100]; vm.estimatedSizes = [input: 250]
        XCTAssertEqual(vm.estimatedChangeColor, .orange)
        XCTAssertEqual(vm.estimatedSavedPercent, -150)
        XCTAssertEqual(vm.estimatedChangeText, "约增加 150%")
        vm.estimatedSizes = [:]
        XCTAssertEqual(vm.estimatedChangeText, "待估算")
    }
    private func detailedJPEG() throws -> URL {
        let width = 1536, height = 1024
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 20261007
        for i in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 1664525 &+ 1013904223
            bytes[i] = UInt8(truncatingIfNeeded: seed >> 24)
            bytes[i + 1] = UInt8(truncatingIfNeeded: seed >> 16)
            bytes[i + 2] = UInt8(truncatingIfNeeded: seed >> 8)
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = path("detail.jpg")
        try ImageCodec.encode(image, type: .jpeg, quality: 0.85).write(to: url)
        return url
    }
    func testFullResolutionJPEGEstimatesMatchExportAtEveryPreset() throws {
        let input = try detailedJPEG(), service = ImageCompressionService()
        let original = try Data(contentsOf: input)
        for level in [CompressionLevel.light, .balanced, .strong] {
            let output = path(level.rawValue + ".jpg")
            let estimate = try service.estimateCompressedSize(url: input, quality: level.qualityValue,
                maxDimension: nil, outputFormat: .keepOriginal)
            try service.compress(url: input, quality: level.qualityValue, maxDimension: nil,
                outputFormat: .keepOriginal, outputURL: output)
            XCTAssertEqual(estimate, FileUtils.fileSize(of: output), level.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: input), original)
    }
    func testEstimatesMatchFormatConversionAndAllSizeModes() throws {
        let input = try detailedJPEG(), service = ImageCompressionService()
        let formats: [OutputFormat] = [.jpg, .png]
        let sizes: [(CGFloat?, CGSize?, CGSize?)] = [
            (800, nil, nil), (nil, CGSize(width: 713, height: 281), nil),
            (nil, nil, CGSize(width: 900, height: 500))
        ]
        for (index, sizing) in sizes.enumerated() {
            for format in formats {
                let output = path("mode-\(index)-\(format.rawValue)")
                let estimate = try service.estimateCompressedSize(url: input, quality: 0.42,
                    maxDimension: sizing.0, outputFormat: format, targetSize: sizing.1, fitWithin: sizing.2)
                try service.compress(url: input, quality: 0.42, maxDimension: sizing.0,
                    outputFormat: format, outputURL: output, targetSize: sizing.1, fitWithin: sizing.2)
                XCTAssertEqual(estimate, FileUtils.fileSize(of: output), "\(format.rawValue) / \(index)")
            }
        }
    }
    func testHEICEstimateMatchesExportWhenEncoderIsAvailable() throws {
        guard ImageCodec.supports(.heic) else { throw XCTSkip("本机没有 HEIC 编码器") }
        let input = try fixture(width: 640, height: 480)
        let probe = try ImageCodec.load(at: input, size: CGSize(width: 640, height: 480))
        do { _ = try ImageCodec.encode(probe, type: .heic, quality: 0.42) }
        catch { throw XCTSkip("当前测试进程无法使用系统 HEIC 编码器：\(error.localizedDescription)") }
        let service = ImageCompressionService(), output = path("estimate.heic")
        let estimate = try service.estimateCompressedSize(url: input, quality: 0.42, maxDimension: 400, outputFormat: .heic)
        try service.compress(url: input, quality: 0.42, maxDimension: 400, outputFormat: .heic, outputURL: output)
        XCTAssertEqual(estimate, FileUtils.fileSize(of: output))
    }
    @MainActor func testLatestEstimateAndCompletedBatchTotalsAgree() async throws {
        let first = try detailedJPEG(), second = try fixture("second.png", width: 700, height: 500)
        let vm = ImageCompressionViewModel(); vm.addImages(from: [first, second])
        XCTAssertEqual(vm.estimatedSizeText, "计算中…")
        vm.selectCompressionLevel(.light)
        vm.outputFormat = .jpg; vm.refreshEstimates()
        // 快速更改参数，旧预估不得回填。
        vm.selectCompressionLevel(.strong)
        vm.sizeMode = .custom; vm.customWidth = "303"; vm.customHeight = "101"
        vm.outputFormat = .png; vm.refreshEstimates()
        for _ in 0..<1000 where vm.isEstimating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(vm.hasCompleteEstimate)
        let before = vm.estimatedSizes
        let service = ImageCompressionService()
        for input in [first, second] {
            let expected = try service.estimateCompressedSize(url: input, quality: 0.42, maxDimension: nil,
                outputFormat: .png, targetSize: CGSize(width: 303, height: 101))
            XCTAssertEqual(before[input], expected)
        }
        vm.executeCompression()
        for _ in 0..<1000 where vm.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(vm.results.count, 2)
        for result in vm.results {
            XCTAssertEqual(before[result.originalURL], result.compressedSize)
            XCTAssertEqual(vm.estimatedSizes[result.originalURL], result.compressedSize)
        }
        XCTAssertEqual(vm.estimatedSizeText, FileUtils.formatSize(vm.results.reduce(0) { $0 + $1.compressedSize }))
    }
    @MainActor func testFailedEstimateDoesNotShowZeroOrSuccessColor() async throws {
        let input = try fixture()
        let vm = ImageCompressionViewModel(); vm.addImages(from: [input])
        vm.compressionLevel = .custom; vm.quality = .nan; vm.refreshEstimates()
        for _ in 0..<500 where vm.isEstimating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(vm.estimatedSizeText, "无法预估")
        XCTAssertEqual(vm.estimatedChangeText, "无法预估")
        XCTAssertNotEqual(vm.estimatedChangeColor, AppColors.success)
        XCTAssertFalse(vm.hasCompleteEstimate)
    }
    func testMultipleImagePagesAreNotSilentlyDiscarded() throws {
        let png = try fixture()
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(png as CFURL, nil)!, 0, nil)!
        let input = path("two-pages.tiff"), output = path("output.png")
        let destination = CGImageDestinationCreateWithURL(input as CFURL, UTType.tiff.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(destination, image, nil); CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let old = Data("existing".utf8); try old.write(to: output)
        XCTAssertThrowsError(try FormatConversionService().convert(url: input, to: .png, outputURL: output))
        XCTAssertEqual(try Data(contentsOf: output), old)
    }
    func testCustomDimensionsAreExact() throws {
        let input = try fixture()
        let output = path("custom.png")
        try ImageCompressionService().compress(url: input, quality: 0.1, maxDimension: nil, outputFormat: .png,
            outputURL: output, targetSize: CGSize(width: 77, height: 31))
        XCTAssertEqual(try ImageCodec.dimensions(at: output), CGSize(width: 77, height: 31))
    }
    func testBoundingBoxPreservesAspectRatio() throws {
        let input = try fixture()
        let output = path("fit.png")
        try ImageCompressionService().compress(url: input, quality: 0.7, maxDimension: nil, outputFormat: .png,
            outputURL: output, fitWithin: CGSize(width: 200, height: 100))
        XCTAssertEqual(try ImageCodec.dimensions(at: output), CGSize(width: 160, height: 100))
    }
    func testMaximumDimensionNeverEnlarges() throws {
        let input = try fixture()
        let output = path("small.png")
        try ImageCompressionService().compress(url: input, quality: 0.7, maxDimension: 2048, outputFormat: .png, outputURL: output)
        XCTAssertEqual(try ImageCodec.dimensions(at: output), CGSize(width: 320, height: 200))
    }
    func testPNGQualityDoesNotPosterizePixels() throws {
        let input = try fixture(width: 256, height: 20)
        let output = path("lossless.png")
        try ImageCompressionService().compress(url: input, quality: 0.1, maxDimension: nil, outputFormat: .png, outputURL: output)
        XCTAssertEqual(try pixels(input), try pixels(output))
    }
    func testTransparentJPEGHasWhiteBackground() throws {
        let input = try fixture(width: 32, height: 32, transparent: true)
        let output = path("white.jpg")
        try FormatConversionService().convert(url: input, to: .jpg, outputURL: output)
        let rgba = try pixels(output)
        XCTAssertGreaterThan(rgba[0], 245); XCTAssertGreaterThan(rgba[1], 245); XCTAssertGreaterThan(rgba[2], 245)
    }
    func testTransparencySurvivesPNG() throws {
        let input = try fixture(width: 16, height: 16, transparent: true)
        let output = path("transparent.png")
        try FormatConversionService().convert(url: input, to: .png, outputURL: output)
        XCTAssertEqual(try pixels(output)[3], 0)
    }
    func testEXIFOrientationIsAppliedWithoutResizing() throws {
        let input = try fixture()
        let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(input as CFURL, nil)!, 0, nil)!
        let jpeg = path("rotated.jpg")
        let destination = CGImageDestinationCreateWithURL(jpeg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let output = path("upright.png")
        try FormatConversionService().convert(url: jpeg, to: .png, outputURL: output)
        XCTAssertEqual(try ImageCodec.dimensions(at: output), CGSize(width: 200, height: 320))
        let properties = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil) as! [CFString: Any]
        XCTAssertEqual((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
    }
    func testOutputBytesMatchSelectedFormat() throws {
        let input = try fixture()
        for format in [ConversionFormat.jpg, .png, .bmp, .tiff] {
            let output = path("converted." + format.fileExtension)
            try FormatConversionService().convert(url: input, to: format, outputURL: output)
            XCTAssertEqual(try ImageCodec.sourceType(at: output).identifier, format.uti as String)
        }
    }
    func testUnavailableFormatsAreNotOffered() {
        for format in ConversionFormat.available { XCTAssertTrue(ImageCodec.writableTypes.contains(format.uti as String)) }
        if !ImageCodec.supports(.webP) { XCTAssertFalse(ConversionFormat.available.contains(.webp)); XCTAssertFalse(OutputFormat.available.contains(.webp)) }
    }
    func testCorruptInputReturnsError() throws {
        let input = path("bad.png"); try Data("bad".utf8).write(to: input)
        XCTAssertThrowsError(try FormatConversionService().convert(url: input, to: .png, outputURL: path("output.png")))
    }
    func testInvalidDimensionsAreRejected() {
        for size in [CGSize(width: 0, height: 100), CGSize(width: 17000, height: 1), CGSize(width: 10000, height: 10000)] {
            XCTAssertThrowsError(try ImageCodec.outputSize(original: CGSize(width: 200, height: 100), maxDimension: nil, targetSize: size, fitWithin: nil))
        }
    }
    func testInvalidQualityAndSameFileDoNotModifySource() throws {
        let input = try fixture(); let data = try Data(contentsOf: input)
        XCTAssertThrowsError(try ImageCompressionService().compress(url: input, quality: .nan, maxDimension: nil, outputFormat: .jpg, outputURL: path("nan.jpg")))
        XCTAssertThrowsError(try ImageCompressionService().compress(url: input, quality: 0.7, maxDimension: nil, outputFormat: .png, outputURL: input))
        XCTAssertEqual(try Data(contentsOf: input), data)
    }
    func testExportPreservesExistingFilesAndNumbersDuplicates() throws {
        let source = path("source.txt"), destination = path("existing.txt")
        try Data("new".utf8).write(to: source); try Data("old".utf8).write(to: destination)
        let first = try FileUtils.safeCopy(from: source, to: destination)
        let second = try FileUtils.safeCopy(from: source, to: destination)
        XCTAssertEqual(first.lastPathComponent, "existing (1).txt"); XCTAssertEqual(second.lastPathComponent, "existing (2).txt")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "new")
    }
    func testExportFailureNeverDeletesExistingDestination() throws {
        let destination = path("existing.txt"); try Data("old".utf8).write(to: destination)
        XCTAssertThrowsError(try FileUtils.safeCopy(from: path("missing"), to: destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.txt"])
    }
    private func previews(_ files: [URL], find: String = "abc", replace: String = "new") -> [RenamePreviewItem] {
        FileRenameService().generatePreview(files: files, mode: .replace, prefix: "", suffix: "", findText: find,
            replaceText: replace, numberText: "", startNumber: 1, numberDigits: 3)
    }
    func testRenameSkipsUnchangedFilesAndCanUndo() throws {
        let a = path("abc.txt"), b = path("other.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let result = FileRenameService().execute(previewItems: previews([a, b]), progressHandler: { _ in })
        guard case .success(let moves) = result else { return XCTFail("Rename failed") }
        XCTAssertEqual(moves.count, 1)
        XCTAssertEqual(moves[0].renamed.lastPathComponent, "new.txt")
        guard case .success = FileRenameService().undo(moves) else { return XCTFail("Undo failed") }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b")
    }
    func testRenameCollisionMatchesPreview() throws {
        let input = path("abc.txt"), existing = path("new.txt")
        try Data("input".utf8).write(to: input); try Data("existing".utf8).write(to: existing)
        let preview = previews([input]); XCTAssertEqual(preview[0].newName, "new (1).txt")
        guard case .success(let moves) = FileRenameService().execute(previewItems: preview, progressHandler: { _ in }) else { return XCTFail() }
        XCTAssertEqual(moves[0].renamed.lastPathComponent, preview[0].newName)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
    }
    func testInvalidRenameCannotMoveFileOutOfDirectory() throws {
        let input = path("abc.txt"); try Data("input".utf8).write(to: input)
        let preview = previews([input], replace: "../escape")
        XCTAssertNotNil(preview[0].conflictReason)
        guard case .failure = FileRenameService().execute(previewItems: preview, progressHandler: { _ in }) else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }
    func testStalePreviewDoesNotPartiallyRename() throws {
        let a = path("abc1.txt"), b = path("abc2.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let preview = previews([a, b]); try Data("external".utf8).write(to: path("new2.txt"))
        guard case .failure = FileRenameService().execute(previewItems: preview, progressHandler: { _ in }) else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
    }
    func testMidBatchRenameFailureRollsBack() throws {
        let a = path("abc1.txt"), b = path("abc2.txt"), conflict = path("new2.txt")
        try Data("a".utf8).write(to: a); try Data("b".utf8).write(to: b)
        let result = FileRenameService().execute(previewItems: previews([a, b]), progressHandler: { progress in
            if progress == 0.5 { try? Data("external".utf8).write(to: conflict) }
        })
        guard case .failure = result else { return XCTFail("Expected rollback") }
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "a"); XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "b")
        XCTAssertEqual(try String(contentsOf: conflict, encoding: .utf8), "external")
    }
    func testPDFMergePreservesPageCountAndText() throws {
        let a = try pdf("a.pdf", pages: 2), b = try pdf("b.pdf", pages: 1), output = path("merged.pdf")
        try PDFService().merge(urls: [a, b], outputURL: output)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 3)
        XCTAssertTrue(PDFDocument(url: output)?.string?.contains("RUITU") == true)
    }
    func testPDFSplitValidatesAllRangesAndPreservesOrder() throws {
        let input = try pdf("three.pdf", pages: 3)
        let ranges = try PageRangeParser.parse("3，1-2", pageCount: 3)
        let files = try PDFService().split(url: input, ranges: ranges, outputDir: path("split"))
        XCTAssertEqual(files.count, 2); XCTAssertEqual(PDFDocument(url: files[0])?.pageCount, 1)
        XCTAssertTrue(PDFDocument(url: files[0])?.string?.contains("Page 3") == true)
        XCTAssertEqual(PDFDocument(url: files[1])?.pageCount, 2)
    }
    func testMalformedAndOutOfRangePDFRangesAreRejected() throws {
        for value in ["0", "4", "2-1", "1-2,garbage", "1,", "-1", "1--2"] {
            XCTAssertThrowsError(try PageRangeParser.parse(value, pageCount: 3))
        }
        let input = try pdf("one.pdf")
        XCTAssertThrowsError(try PDFService().split(url: input, ranges: [SplitRange(start: 8, end: 10)], outputDir: path("invalid")))
    }
    func testPDFEncryptionRestrictsPrintingAndCopying() throws {
        let input = try pdf("plain.pdf"), output = path("encrypted.pdf")
        try PDFService().encrypt(url: input, config: EncryptionConfig(userPassword: "reader", ownerPassword: "owner", allowPrinting: false, allowCopying: false), outputURL: output)
        let doc = PDFDocument(url: output)!
        XCTAssertTrue(doc.isLocked); XCTAssertFalse(doc.unlock(withPassword: "wrong")); XCTAssertTrue(doc.unlock(withPassword: "reader"))
        XCTAssertFalse(doc.allowsPrinting); XCTAssertFalse(doc.allowsCopying)
    }
    func testEncryptedPDFCannotBeMergedWithoutPassword() throws {
        let input = try pdf("plain.pdf"), encrypted = path("locked.pdf")
        try PDFService().encrypt(url: input, config: EncryptionConfig(userPassword: "reader", ownerPassword: "owner", allowPrinting: true, allowCopying: true), outputURL: encrypted)
        XCTAssertThrowsError(try PDFService().merge(urls: [input, encrypted], outputURL: path("badmerge.pdf")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("badmerge.pdf").path))
    }
    func testWatermarkPreservesPagesRotationAndAnnotations() throws {
        let input = try pdf("plain.pdf")
        let doc = PDFDocument(url: input)!, page = doc.page(at: 0)!
        page.rotation = 90
        page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 40, height: 20), forType: .text, withProperties: nil))
        XCTAssertTrue(doc.write(to: input))
        let output = path("watermark.pdf")
        try PDFService().addWatermark(url: input, type: .text("DRAFT", fontSize: 24, color: CGColor(gray: 0.5, alpha: 1), rotation: -45, opacity: 0.3), outputURL: output)
        let result = PDFDocument(url: output)!
        XCTAssertEqual(result.pageCount, 1); XCTAssertEqual(result.page(at: 0)?.rotation, 90)
        XCTAssertEqual(result.page(at: 0)?.annotations.count, PDFDocument(url: input)?.page(at: 0)?.annotations.count)
        XCTAssertTrue(result.string?.contains("RUITU") == true); XCTAssertTrue(result.string?.contains("DRAFT") == true)
    }
    func testMissingWatermarkImageCannotProducePartialPDF() throws {
        let input = try pdf("plain.pdf"), output = path("output.pdf")
        try Data("existing".utf8).write(to: output)
        XCTAssertThrowsError(try PDFService().addWatermark(url: input, type: .image(path("missing.png"), scale: 1, opacity: 0.3), outputURL: output))
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "existing")
    }
    func testBasicWordPDFConversionKeepsAllText() throws {
        let input = path("document.docx")
        let string = NSAttributedString(string: String(repeating: "RUITU document line\n", count: 120), attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let data = try string.data(from: NSRange(location: 0, length: string.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: input)
        let output = path("document.pdf")
        try DocumentConversionService().wordToPDF(url: input, outputURL: output)
        let document = PDFDocument(url: output)!
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertEqual(document.string?.components(separatedBy: "RUITU").count, 121)
        let extracted = path("extracted.docx")
        try DocumentConversionService().pdfToWord(url: output, outputURL: extracted)
        let word = try NSAttributedString(data: Data(contentsOf: extracted), options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertEqual(word.string.components(separatedBy: "RUITU").count, 121)
    }
    @MainActor func testImageBatchUsesUniqueOutputsForSameNamedInputs() async throws {
        let first = try fixture("same.png", width: 80, height: 60)
        let secondDir = path("second"); try FileManager.default.createDirectory(at: secondDir, withIntermediateDirectories: true)
        let second = secondDir.appendingPathComponent("same.png")
        let other = try fixture("other.png", width: 40, height: 20); try FileManager.default.copyItem(at: other, to: second)
        let vm = ImageCompressionViewModel(); vm.addImages(from: [first, second]); vm.outputFormat = .png
        vm.executeCompression()
        for _ in 0..<500 where vm.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(vm.isProcessing); XCTAssertEqual(vm.results.count, 2)
        guard vm.results.count == 2 else { return }
        XCTAssertNotEqual(vm.results[0].compressedURL, vm.results[1].compressedURL)
        XCTAssertEqual(try ImageCodec.dimensions(at: vm.results[0].compressedURL), CGSize(width: 80, height: 60))
        XCTAssertEqual(try ImageCodec.dimensions(at: vm.results[1].compressedURL), CGSize(width: 40, height: 20))
    }
    @MainActor func testImageCancellationReleasesProcessingState() async throws {
        let input = try fixture()
        let vm = ImageCompressionViewModel(); vm.addImages(from: [input]); vm.executeCompression(); vm.cancelProcessing()
        for _ in 0..<500 where vm.isProcessing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(vm.isProcessing)
        XCTAssertTrue(vm.successMessage?.contains("已停止") == true)
    }
    private func audio(_ name: String, silence: Bool = false, fullScale: Bool = false) throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!
        buffer.frameLength = 16000
        for i in 0..<16000 {
            if silence || (!fullScale && (i < 3200 || i >= 12800)) { buffer.int16ChannelData![0][i] = 0 }
            else { buffer.int16ChannelData![0][i] = fullScale ? -32768 : Int16(sin(Double(i) * 2 * .pi * 440 / 16000) * 18000) }
        }
        let url = path(name)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
        return url
    }
    func testAudioVADSilenceDoesNotCrashOrReportSpeech() throws {
        let file = try audio("silent.wav", silence: true)
        XCTAssertTrue(try AudioPreprocessor().detectSpeechSegments(url: file).isEmpty)
    }
    func testAudioVADFindsToneAndPreservesSilentBoundaries() throws {
        let file = try audio("tone.wav")
        let segments = try AudioPreprocessor().detectSpeechSegments(url: file)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startTime, 0.2, accuracy: 0.03)
        XCTAssertEqual(segments[0].endTime, 0.8, accuracy: 0.03)
    }
    func testAudioNormalizationHandlesMinimumInt16() async throws {
        let file = try audio("fullscale.wav", fullScale: true)
        let output = try await AudioPreprocessor().preprocess(sourceURL: file, enableNoiseReduction: false)
        let result = try AVAudioFile(forReading: output)
        XCTAssertEqual(result.fileFormat.sampleRate, 16000)
        XCTAssertEqual(result.fileFormat.channelCount, 1)
        XCTAssertGreaterThan(result.length, 15000)
    }
    func testAudioTrimPreservesRequestedDuration() async throws {
        let input = try audio("tone.wav")
        let output = try await AudioPreprocessor().trimSilence(url: input, startTime: 0.2, endTime: 0.5)
        let result = try AVAudioFile(forReading: output)
        XCTAssertEqual(Double(result.length) / result.fileFormat.sampleRate, 0.3, accuracy: 0.002)
    }
    func testGIFCompressionPreservesTimingAndLoopCount() throws {
        let imageURL = try fixture(width: 40, height: 20)
        let frame = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(imageURL as CFURL, nil)!, 0, nil)!
        let input = path("timed.gif")
        let destination = CGImageDestinationCreateWithURL(input as CFURL, UTType.gif.identifier as CFString, 4, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 2]] as CFDictionary)
        for delay in [0.1, 0.2, 0.3, 0.4] {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let output = path("compressed.gif")
        let result = try GIFGenerationService().compressGIF(url: input, maxDimension: 20, frameSkip: 2, outputURL: output, progressHandler: { _, _ in })
        XCTAssertEqual(result.frameCount, 2); XCTAssertEqual(result.duration, 1, accuracy: 0.02)
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)!
        let properties = CGImageSourceCopyProperties(source, nil) as! [CFString: Any]
        let gif = properties[kCGImagePropertyGIFDictionary] as! [CFString: Any]
        XCTAssertEqual((gif[kCGImagePropertyGIFLoopCount] as? NSNumber)?.intValue, 2)
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        XCTAssertEqual((first[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 20)
    }
    func testGIFRejectsInvalidParametersWithoutTouchingSource() throws {
        let input = try fixture(), old = try Data(contentsOf: input)
        XCTAssertThrowsError(try GIFGenerationService().generateGIF(from: input, frameRate: 0, maxDimension: 400, startTime: 0, duration: 2, outputURL: path("bad.gif"), progressHandler: { _, _ in }))
        XCTAssertEqual(try Data(contentsOf: input), old)
    }
    func testCaseOnlyRenameMatchesPreviewAndCanUndo() throws {
        let input = path("abc.txt"); try Data("input".utf8).write(to: input)
        let preview = previews([input], replace: "ABC")
        XCTAssertEqual(preview[0].newName, "ABC.txt")
        guard case .success(let moves) = FileRenameService().execute(previewItems: preview, progressHandler: { _ in }) else { return XCTFail() }
        guard case .success = FileRenameService().undo(moves) else { return XCTFail() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: input.path))
    }
    func testPDFTextRecognitionKeepsPageOrder() async throws {
        let input = try pdf("text.pdf", pages: 2)
        let text = try await OCRService().recognizePDF(url: input, progressHandler: { _, _ in })
        XCTAssertTrue(text.contains("Page 1")); XCTAssertTrue(text.contains("Page 2"))
        XCTAssertLessThan(text.range(of: "Page 1")!.lowerBound, text.range(of: "Page 2")!.lowerBound)
    }

}
