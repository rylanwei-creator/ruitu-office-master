import XCTest
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import RuiTuOfficeMaster

final class ImageTargetCompressionTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("TargetImageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture(type: UTType = .jpeg, transparent: Bool = false, width: Int = 900, height: Int = 600) throws -> URL {
        var bytes = [UInt8](repeating: 255, count: width * height * 4), seed: UInt32 = 17
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            seed = seed &* 1664525 &+ 1013904223
            if transparent && x < width / 4 { bytes[i] = 0; bytes[i+1] = 0; bytes[i+2] = 0; bytes[i+3] = 0 }
            else { bytes[i] = UInt8(truncatingIfNeeded: seed >> 24); bytes[i+1] = UInt8(truncatingIfNeeded: seed >> 16); bytes[i+2] = UInt8(truncatingIfNeeded: seed >> 8) }
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(type.preferredFilenameExtension!)
        try ImageCodec.encode(image, type: type, quality: 0.85).write(to: url)
        return url
    }
    private func options(_ goal: ImageSizeGoal, format: OutputFormat = .keepOriginal, floor: Double = 0.3, resize: Bool = true) -> ImageTargetOptions {
        .init(goal: goal, format: format, qualityFloor: floor, maxDimension: nil, targetSize: nil, fitWithin: nil, allowResize: resize)
    }
    func testJPEGPresetsActuallyReduceBytesWithoutChangingSource() throws {
        let url = try fixture(), original = try Data(contentsOf: url)
        if let folder = ProcessInfo.processInfo.environment["RUITU_COMPRESSION_QA_DIR"] {
            let target = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try original.write(to: target.appendingPathComponent("测试照片.jpg"))
        }
        var counts: [Int] = []
        for level in [CompressionLevel.light, .balanced, .strong] {
            let result = try ImageTargetCompressor().compress(url, options: options(.reduction(level.reductionFraction), floor: level.qualityValue))
            let ceiling = Int((Double(original.count) * (1 - level.reductionFraction)).rounded(.down))
            XCTAssertTrue(result.targetMet)
            XCTAssertLessThanOrEqual(result.data.count, ceiling)
            XCTAssertGreaterThan(result.data.count, Int(Double(ceiling) * 0.80), "Avoid excessive compression past the requested target")
            counts.append(result.data.count)
            print("TARGET_QA \(level.rawValue): \(original.count) -> \(result.data.count) bytes; \(result.dimensions); quality \(result.quality)")
        }
        XCTAssertGreaterThan(counts[0], counts[1]); XCTAssertGreaterThan(counts[1], counts[2])
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testCustomRangeAndAutomaticResize() throws {
        let url = try fixture()
        let result = try ImageTargetCompressor().compress(url, options: options(.range(minimum: 50_000, maximum: 70_000), floor: 0.85))
        print("CUSTOM_QA \(result.data.count) bytes; \(result.dimensions); \(result.quality); \(result.detail)")
        XCTAssertTrue(result.targetMet)
        XCTAssertTrue((50_000...70_000).contains(result.data.count))
        XCTAssertLessThan(result.dimensions.width, 900)
        XCTAssertLessThanOrEqual(result.quality, 1)
        XCTAssertGreaterThanOrEqual(result.quality, 0.85)
    }
    func testFixedDimensionsDoNotGrowOutputOrSilentlyShrink() throws {
        let url = try fixture()
        let result = try ImageTargetCompressor().compress(url, options: options(.reduction(0.99), floor: 0.6, resize: false))
        XCTAssertEqual(result.dimensions, CGSize(width: 900, height: 600))
        XCTAssertLessThanOrEqual(Int64(result.data.count), FileUtils.fileSize(of: url))
        XCTAssertFalse(result.targetMet)
        XCTAssertTrue(result.detail.hasPrefix("未达到目标"))
        XCTAssertThrowsError(try ImageTargetCompressor().compress(url, options: options(.reduction(0.99), format: .png, resize: false)))
    }
    func testTransparentPNGTargetsUseDimensionsAndKeepAlpha() throws {
        let url = try fixture(type: .png, transparent: true)
        let result = try ImageTargetCompressor().compress(url, options: options(.reduction(0.5)))
        XCTAssertTrue(result.targetMet)
        XCTAssertLessThanOrEqual(Int64(result.data.count), FileUtils.fileSize(of: url) / 2)
        XCTAssertLessThan(result.dimensions.width, 900)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertNotEqual(image.alphaInfo, .none)
        let bitmap = NSBitmapImageRep(cgImage: image)
        XCTAssertEqual(bitmap.colorAt(x: 1, y: 1)?.alphaComponent, 0)
    }
    func testImpossibleTinyTargetAndBelowRangeAreExplicit() throws {
        let url = try fixture(type: .png, width: 1, height: 1)
        let original = try Data(contentsOf: url)
        let tiny = try ImageTargetCompressor().compress(url, options: options(.range(minimum: 1, maximum: 2)))
        XCTAssertFalse(tiny.targetMet); XCTAssertEqual(tiny.data, original)
        let below = try ImageTargetCompressor().compress(url, options: options(.range(minimum: 10_000, maximum: 20_000)))
        XCTAssertFalse(below.targetMet); XCTAssertLessThanOrEqual(below.data.count, original.count)
        XCTAssertFalse(below.detail.hasPrefix("达到"))
    }
    func testInvalidRangesAreRejected() throws {
        for goal in [ImageSizeGoal.range(minimum: 0, maximum: 5), .range(minimum: 5, maximum: 4), .range(minimum: 1, maximum: 1_000_000_001), .reduction(.nan)] {
            XCTAssertThrowsError(try goal.bounds(original: 1000))
        }
    }
    func testOriginalAlreadyWithinRangeKeepsItsExactBytes() throws {
        let url = try fixture(), original = try Data(contentsOf: url)
        let result = try ImageTargetCompressor().compress(url, options: options(.range(minimum: Int64(original.count - 10), maximum: Int64(original.count + 10))))
        XCTAssertTrue(result.targetMet); XCTAssertEqual(result.data, original)
    }
    func testTamperedPreviewIsRejected() async throws {
        let input = try fixture()
        let prepared = try await ImageCompressionWorker.shared.prepareTarget(url: input, options: options(.reduction(0.5)), directory: directory.appendingPathComponent("preview"))
        var bytes = try Data(contentsOf: prepared.url); bytes[bytes.count - 1] ^= 1
        try bytes.write(to: prepared.url)
        let output = directory.appendingPathComponent("tampered.jpg")
        do {
            try await ImageCompressionWorker.shared.exportTarget(url: input, prepared: prepared, outputURL: output)
            XCTFail("A changed trial file cannot be exported")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: output.path)) }
    }
    func testCancelledTrialDoesNotLeaveFiles() async throws {
        let input = try fixture(), folder = directory.appendingPathComponent("cancelled")
        let settings = options(.reduction(0.5))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ImageCompressionWorker.shared.prepareTarget(url: input, options: settings, directory: folder)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    func testPreparedBytesAreExactlyExportedAndChangesAreRejected() async throws {
        let input = try fixture()
        let prepared = try await ImageCompressionWorker.shared.prepareTarget(url: input, options: options(.reduction(0.5)), directory: directory.appendingPathComponent("preview"))
        let output = directory.appendingPathComponent("export.jpg")
        try await ImageCompressionWorker.shared.exportTarget(url: input, prepared: prepared, outputURL: output)
        XCTAssertEqual(try Data(contentsOf: prepared.url), try Data(contentsOf: output))
        XCTAssertEqual(FileUtils.fileSize(of: output), prepared.byteCount)
        try Data("changed source".utf8).write(to: input)
        do {
            try await ImageCompressionWorker.shared.exportTarget(url: input, prepared: prepared, outputURL: directory.appendingPathComponent("changed.jpg"))
            XCTFail("Changed source must invalidate the preview")
        } catch { XCTAssertTrue(error is TargetCompressionError) }
    }
    func testLegacyTaskOutputDecodesWithoutDetails() throws {
        let data = Data("{\"url\":\"file:///tmp/test.png\",\"inputSize\":100,\"outputSize\":50}".utf8)
        XCTAssertNil(try JSONDecoder().decode(FileTaskOutput.self, from: data).detail)
    }
    @MainActor func testCustomValidationAndChangingGoalInvalidateOldPreview() async throws {
        let url = try fixture()
        let vm = ImageCompressionViewModel()
        vm.addImages(from: [url]); vm.selectCompressionLevel(.custom)
        vm.customMinimum = "50"; vm.customMaximum = "70"; vm.customSizeUnit = "KB"
        XCTAssertFalse(vm.canExecute)
        for _ in 0..<1500 where vm.isEstimating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(vm.hasCompleteEstimate); XCTAssertTrue(vm.canExecute)
        XCTAssertTrue((50_000...70_000).contains(vm.estimatedSizes[url] ?? 0))
        vm.customMinimum = "80"
        XCTAssertNotNil(vm.validationMessage); XCTAssertFalse(vm.canExecute)
        XCTAssertFalse(vm.hasCompleteEstimate)
        vm.customMinimum = "nan"
        XCTAssertNotNil(vm.validationMessage)
    }
}
