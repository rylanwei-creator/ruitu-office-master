import XCTest
import AppKit
import CoreText
@testable import RuiTuOfficeMaster

final class OCRResultTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ruitu-ocr-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(_ name: String, text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = CGContext(data: nil, width: 1000, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 300))
        context.textPosition = CGPoint(x: 45, y: 150)
        let line = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 54), .foregroundColor: NSColor.black])
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        try ImageCodec.encode(context.makeImage()!, type: .png, quality: 1).write(to: url)
        return url
    }

    func testBatchRetainsSourceOrderSameNamesAndPartialFailures() async throws {
        let first = try fixture("甲/photo.png", text: "RUITU ALPHA 123")
        let second = try fixture("乙/photo.png", text: "RUITU BETA 456")
        let blank = try fixture("空白.png", text: "")
        let broken = directory.appendingPathComponent("损坏.png")
        try Data("invalid image".utf8).write(to: broken)
        let service = OCRService()
        let results = try await service.recognizeBatchResults(urls: [first, blank, broken, second], recognize: { url in
            _ = try service.loadImage(from: url)
            if url == blank { throw OCRError.noTextFound }
            return url == first ? "RUITU ALPHA 123" : "RUITU BETA 456"
        }) { _, _ in }
        XCTAssertEqual(results.map(\.sourceURL), [first, blank, broken, second])
        XCTAssertEqual(Set(results.map(\.id)).count, 4)
        XCTAssertTrue(results[0].text.contains("ALPHA"), results[0].notice ?? results[0].text)
        XCTAssertFalse(results[0].text.contains("BETA"))
        XCTAssertTrue(results[3].text.contains("BETA"), results[3].notice ?? results[3].text)
        XCTAssertEqual(results[1].status, .noText)
        if case .failed = results[2].status {} else { XCTFail("损坏图片必须单独标记失败") }
    }

    func testBatchCancellationDoesNotBecomeAFileFailure() async throws {
        do {
            _ = try await OCRService().recognizeBatchResults(urls: [URL(fileURLWithPath: "/a.png")], recognize: { _ in
                throw CancellationError()
            }) { _, _ in }
            XCTFail("取消必须向上传播")
        } catch is CancellationError {} catch { XCTFail("错误类型：\(error)") }
    }

    @MainActor func testEditingAndTranslationStayWithSourceEvenWhenResponsesAreReordered() {
        let first = OCRImageResult(sourceURL: URL(fileURLWithPath: "/甲/photo.png"), text: "Alpha")
        let second = OCRImageResult(sourceURL: URL(fileURLWithPath: "/乙/photo.png"), text: "Beta")
        let vm = OCRViewModel(); vm.imageResults = [first, second]
        let inputs = vm.imageResults.map { (id: $0.id.uuidString, text: $0.text) }
        vm.applyTranslations([(second.id.uuidString, "乙"), (first.id.uuidString, "甲")], inputs: inputs)
        XCTAssertEqual(vm.imageResults.map(\.translatedText), ["甲", "乙"])
        vm.setImageText(id: first.id, text: "Edited Alpha")
        XCTAssertEqual(vm.imageResults.map(\.text), ["Edited Alpha", "Beta"])
        XCTAssertEqual(vm.imageResults.map(\.translatedText), ["", "乙"])
        vm.applyTranslations([(first.id.uuidString, "旧译文")], inputs: inputs)
        XCTAssertEqual(vm.imageResults[0].translatedText, "")
        vm.clearAll()
        vm.applyTranslations([(first.id.uuidString, "旧译文")], inputs: inputs)
        XCTAssertFalse(vm.hasResult)
        XCTAssertFalse(vm.hasTranslation)
    }

    @MainActor func testAllExportsPreserveFullFilenamesAndUserEdits() throws {
        let vm = OCRViewModel()
        vm.imageResults = [
            OCRImageResult(sourceURL: URL(fileURLWithPath: "/照片/同名.png"), text: "--- 原文标题 ---\n第一张"),
            OCRImageResult(sourceURL: URL(fileURLWithPath: "/照片/同名.jpg"), text: "第二张")
        ]
        vm.setImageText(id: vm.imageResults[1].id, text: "修改后的第二张")
        let text = vm.allResultText
        XCTAssertTrue(text.contains("图片 1：同名.png")); XCTAssertTrue(text.contains("图片 2：同名.jpg"))
        XCTAssertTrue(text.contains("--- 原文标题 ---\n第一张")); XCTAssertTrue(text.contains("修改后的第二张"))
        let data = try XCTUnwrap(OCRService.exportAsRTF(text))
        let restored = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue(restored.string.contains("同名.png")); XCTAssertTrue(restored.string.contains("修改后的第二张"))
    }

    @MainActor func testSelectionChangesClearResultsAndFormattingNeverCrossesImages() {
        let vm = OCRViewModel(); vm.importMode = .batchImages
        let url = URL(fileURLWithPath: "/a.png")
        vm.selectedImages = [url]
        vm.imageResults = [OCRImageResult(sourceURL: url, text: "First\nline"),
            OCRImageResult(sourceURL: URL(fileURLWithPath: "/b.png"), text: "Second\nline")]
        let expected = vm.imageResults.map { OCRService.reformatText($0.text) }
        vm.reformatText()
        XCTAssertEqual(vm.imageResults.map(\.text), expected)
        vm.removeFile(url: url)
        XCTAssertFalse(vm.hasResult)
        XCTAssertTrue(vm.imageResults.isEmpty)
        vm.imageResults = [OCRImageResult(sourceURL: url, text: "", status: .noText)]
        XCTAssertTrue(vm.hasResult); XCTAssertFalse(vm.hasText)
        vm.switchImportMode(to: .singleImage)
        XCTAssertFalse(vm.hasResult)
    }
}
