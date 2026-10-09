import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import RuiTuOfficeMaster

final class OCRExperienceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ruitu-ocr-experience-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    @MainActor func testEditorMeasuresWrappedChineseAndTrailingBlankLines() {
        let short = OCRTextLayout.contentHeight(text: "短文字", width: 600)
        XCTAssertEqual(short, 52)
        let text = String(repeating: "这是需要准确换行的识别文字。", count: 80)
        let wide = OCRTextLayout.contentHeight(text: text, width: 700)
        let narrow = OCRTextLayout.contentHeight(text: text, width: 300)
        XCTAssertGreaterThan(wide, OCRTextLayout.collapsedLimit)
        XCTAssertGreaterThan(narrow, wide)
        XCTAssertGreaterThan(OCRTextLayout.contentHeight(text: "一\n二\n三\n\n", width: 300),
                             OCRTextLayout.contentHeight(text: "一\n二\n三", width: 300))
        XCTAssertEqual(OCRTextLayout.contentHeight(text: text, width: 0), 52)
    }

    func testThumbnailIsBoundedAndCorrectsImageOrientation() async throws {
        let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let url = directory.appendingPathComponent("旋转照片.jpg")
        let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(target, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(target))
        let before = try Data(contentsOf: url)
        let image = try await OCRPreviewLoader.load(url, maxDimension: 60)
        XCTAssertLessThanOrEqual(max(image.width, image.height), 60)
        XCTAssertLessThan(image.width, image.height)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testMissingPreviewSourceReturnsAnError() async throws {
        do {
            _ = try await OCRPreviewLoader.load(directory.appendingPathComponent("已移动.png"), maxDimension: 160)
            XCTFail("缺失图片必须报错")
        } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testSeparateExportPreservesEditsFormatsAndExistingFiles() throws {
        let first = OCRImageResult(sourceURL: URL(fileURLWithPath: "/甲/photo.png"), text: "第一张\n修改后的文字")
        let second = OCRImageResult(sourceURL: URL(fileURLWithPath: "/乙/photo.jpg"), text: "第二张")
        let sameName = OCRImageResult(sourceURL: URL(fileURLWithPath: "/丙/photo.png"), text: "同名第三张")
        let blank = OCRImageResult(sourceURL: URL(fileURLWithPath: "/空白.png"), text: "", status: .noText)
        let existing = directory.appendingPathComponent("photo.png_识别结果.txt")
        try "已有内容".write(to: existing, atomically: true, encoding: .utf8)
        let report = OCRTextExporter.export([first, second, sameName, blank], to: directory)
        XCTAssertEqual(report.savedURLs.count, 3); XCTAssertEqual(report.renamedCount, 2)
        XCTAssertEqual(report.skippedCount, 1); XCTAssertTrue(report.errors.isEmpty, report.errors.description)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "已有内容")
        XCTAssertEqual(try report.savedURLs.map { try String(contentsOf: $0, encoding: .utf8) }, [first.text, second.text, sameName.text])
        XCTAssertEqual(Set(report.savedURLs).count, 3)
        XCTAssertTrue(report.savedURLs.contains { $0.lastPathComponent.contains("photo.jpg") })
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains(where: { $0.hasPrefix(".ruit-export-") }))
    }

    func testSeparateExportReportsFailuresAndBoundsLongUnicodeFilenames() throws {
        let longName = String(repeating: "照片", count: 40) + ".png"
        let result = OCRImageResult(sourceURL: URL(fileURLWithPath: "/" + longName), text: "测试")
        let report = OCRTextExporter.export([result], to: directory)
        XCTAssertEqual(report.savedURLs.count, 1); XCTAssertTrue(report.errors.isEmpty, report.errors.description)
        XCTAssertLessThanOrEqual(OCRTextExporter.fileName(for: result).utf8.count, 240)
        XCTAssertTrue(OCRTextExporter.fileName(for: result).hasSuffix(".png_识别结果.txt"))
        let badFolder = directory.appendingPathComponent("不是目录")
        try Data("existing".utf8).write(to: badFolder)
        let failed = OCRTextExporter.export([result], to: badFolder)
        XCTAssertTrue(failed.savedURLs.isEmpty); XCTAssertEqual(failed.errors.count, 1)
        XCTAssertEqual(try Data(contentsOf: badFolder), Data("existing".utf8))
    }
}
