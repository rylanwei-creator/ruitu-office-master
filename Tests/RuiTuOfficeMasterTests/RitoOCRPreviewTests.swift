import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import RuiTuOfficeMaster

final class RitoOCRPreviewTests: XCTestCase {
    func testThumbnailIsBoundedAndRespectsOrientation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 800, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.8, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
        let sourceImage = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sourceImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let data = try XCTUnwrap(RitoImagePreview.data(from: url))
        XCTAssertLessThanOrEqual(data.count, RitoImagePreview.byteLimit)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 240); XCTAssertEqual(image.height, 480)
    }
    func testLegacyAndNewResultsPreserveFullTextAndPreview() throws {
        let text = (1...150).map { "第\($0)行：完整识别文字，禁止截断。" }.joined(separator: "\n") + "\nOCR_END_MARKER"
        let result = RToolAIResult(sourceName: "source.png", detail: text, previewData: Data([1, 2, 3]))
        let restored = try JSONDecoder().decode(RToolAIResult.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(restored.detail, text); XCTAssertEqual(restored.previewData, result.previewData)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        legacy.removeValue(forKey: "previewData")
        let old = try JSONDecoder().decode(RToolAIResult.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.previewData); XCTAssertEqual(old.detail, text)
    }
    func testThumbnailsRemainLocalAndDoNotEnterCloudRequest() throws {
        let bytes = Data("PRIVATE_THUMBNAIL".utf8)
        let attachment = RToolAIAttachment(id: UUID(), name: "PRIVATE_IMAGE.png", byteCount: 123, previewData: bytes)
        let message = RToolAIMessage(id: UUID(), role: .user, text: "先前问题", attachments: [attachment])
        let request = RToolAIRequest(messages: [message], text: "下一步", attachments: [attachment], intent: nil)
        let provider = RitoCustomAPIProvider(endpoint: URL(string: "https://api.example.com/chat/completions")!, model: "fixture")
        let data = try XCTUnwrap(provider.makeRequest(request).httpBody)
        let body = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(body.contains(attachment.name))
        XCTAssertFalse(body.contains(bytes.base64EncodedString()))
        XCTAssertFalse(body.contains("PRIVATE_THUMBNAIL"))
        XCTAssertTrue(body.contains("先前问题"))
    }
    func testUnreadableSourceDoesNotInventPreview() {
        XCTAssertNil(RitoImagePreview.data(from: URL(fileURLWithPath: "/nonexistent-rito-ocr.png")))
        XCTAssertTrue(RitoImagePreview.isImage("scan.JPG"))
        XCTAssertFalse(RitoImagePreview.isImage("document.pdf"))
    }
}
