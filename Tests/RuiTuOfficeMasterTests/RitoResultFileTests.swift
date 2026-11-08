import XCTest
import PDFKit
import AppKit
@testable import RuiTuOfficeMaster

final class RitoResultFileTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rito-file-result-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func pdf(_ url: URL, pages: Int = 1) throws {
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
    }
    func testMergedPDFResultRetainsLocalFileReferenceAfterHistoryRoundTrip() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.pdf"), b = root.appendingPathComponent("b.pdf"), out = root.appendingPathComponent("merged.pdf")
        try pdf(a, pages: 2); try pdf(b, pages: 3); let ids = [UUID(), UUID()]
        let prepared = try RitoToolExecutor.prepare(.init(operation: .pdf_merge, attachmentIDs: ids),
            files: [ids[0]: a, ids[1]: b], destination: out)
        let results = try await RitoToolExecutor.execute(prepared) { _ in }
        let result = try XCTUnwrap(results.first)
        let restored = try JSONDecoder().decode(RToolAIResult.self, from: JSONEncoder().encode(result))
        let url = try XCTUnwrap(restored.fileReference).resolvedURL()
        XCTAssertEqual(url.standardizedFileURL, out.standardizedFileURL)
        XCTAssertEqual(PDFDocument(url: url)?.pageCount, 5)
        XCTAssertEqual(restored.detail, result.detail)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }
    func testBookmarkFollowsRenamedPDF() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appendingPathComponent("before.pdf"), after = root.appendingPathComponent("after.pdf")
        try pdf(before)
        let ref = RitoResultFile.capture(before)
        XCTAssertNotNil(ref.bookmarkData)
        try FileManager.default.moveItem(at: before, to: after)
        XCTAssertEqual(try ref.resolvedURL().standardizedFileURL, after.standardizedFileURL)
    }
    @MainActor private final class Board: RitoFilePasteboard {
        var files: [URL] = []
        var existingText: String? = "sentinel"
        func writeFile(_ url: URL) -> Bool { files = [url]; existingText = nil; return true }
    }
    @MainActor func testCopyPublishesFileURLRatherThanExplanation() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("result.pdf"); try pdf(url)
        let board = Board()
        try RitoResultFileActions.copy(.capture(url), to: board)
        // macOS may return /private/var for the /var temporary-directory alias.
        XCTAssertEqual(board.files.map { $0.resolvingSymlinksInPath() }, [url.resolvingSymlinksInPath()])
        XCTAssertNil(board.existingText)
    }
    @MainActor func testDeletedFileDoesNotEraseClipboardOrInventFile() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("result.pdf"); try pdf(url)
        let ref = RitoResultFile.capture(url)
        try FileManager.default.removeItem(at: url)
        let board = Board()
        XCTAssertThrowsError(try RitoResultFileActions.copy(ref, to: board))
        XCTAssertTrue(board.files.isEmpty)
        XCTAssertEqual(board.existingText, "sentinel")
    }
    func testRemoteAndSymbolicPathsAreRejected() throws {
        XCTAssertThrowsError(try RitoResultFile(url: URL(string: "https://example.com/file.pdf")!).resolvedURL())
        XCTAssertThrowsError(try RitoResultFile(url: URL(string: "file://untrusted.example/file.pdf")!).resolvedURL())
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real.pdf"), link = root.appendingPathComponent("link.pdf")
        try pdf(real); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try RitoResultFile(url: link).resolvedURL())
    }
    func testOutputPathsAndBookmarksStayOutOfCloudContext() throws {
        let ref = RitoResultFile(url: URL(fileURLWithPath: "/Users/PRIVATE_RESULT/result.pdf"), bookmarkData: Data("PRIVATE_BOOKMARK".utf8))
        let result = RToolAIResult(sourceName: "result.pdf", detail: "已合并", fileReference: ref)
        var plan = RToolAITaskPlan(id: UUID(), intent: .pdfDocument, sourceNames: ["a.pdf", "b.pdf"])
        plan.state = .completed; plan.results = [result]
        let message = RToolAIMessage(id: UUID(), role: .assistant, text: "合并完成", task: plan, source: .custom)
        let provider = RitoCustomAPIProvider(endpoint: URL(string: "https://api.example.com/chat/completions")!, model: "fixture")
        let data = try XCTUnwrap(provider.makeRequest(.init(messages: [message], text: "谢谢", attachments: [], intent: nil)).httpBody)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_RESULT"))
        XCTAssertFalse(text.contains(ref.bookmarkData!.base64EncodedString()))
        XCTAssertTrue(text.contains("合并完成"))
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
        old.removeValue(forKey: "fileReference")
        XCTAssertNil(try JSONDecoder().decode(RToolAIResult.self, from: JSONSerialization.data(withJSONObject: old)).fileReference)
    }
}
