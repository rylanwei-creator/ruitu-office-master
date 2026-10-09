import XCTest
import PDFKit
import AppKit
@testable import RuiTuOfficeMaster

final class PDFPreviewTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ruitu-pdf-preview-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func pdf(_ name: String, pages: Int) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 300, height: 420)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for index in 1...pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            context.setFillColor(CGColor(red: CGFloat(index) / CGFloat(pages + 1), green: 0.3, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 30, y: 30, width: 100 + index * 10, height: 80))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "PAGE \(index)", attributes: [.font: NSFont.systemFont(ofSize: 28)]))
            context.textPosition = CGPoint(x: 30, y: 210); CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF(); return url
    }

    @MainActor private func ready(_ preview: PDFSplitPreviewViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (preview.isLoadingDocument || preview.isRenderingPage) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(preview.isLoadingDocument); XCTAssertFalse(preview.isRenderingPage)
    }
    @MainActor private func finish(_ vm: PDFToolsViewModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while vm.isProcessing && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(vm.isProcessing)
    }

    @MainActor func testPageCountRenderingNavigationAndRangeMatchesActualSplitOutputs() async throws {
        let source = try pdf("four.pdf", pages: 4), bytes = try Data(contentsOf: source)
        let vm = PDFToolsViewModel(); vm.selectedTool = .split; vm.addFiles(from: [source])
        try await ready(vm.splitPreview)
        XCTAssertEqual(vm.splitPreview.pageCount, 4); XCTAssertEqual(vm.splitPreview.currentPage, 1)
        XCTAssertNotNil(vm.splitPreview.image); XCTAssertNil(vm.splitPreview.documentError)
        let firstImage = try XCTUnwrap(vm.splitPreview.image?.tiffRepresentation)
        vm.splitRangesText = "1-2, 4"
        XCTAssertNil(vm.splitRangeError); XCTAssertTrue(vm.canExecute)
        XCTAssertEqual(vm.parsePageRangesForDisplay, ["第1-2页", "第4页"])
        XCTAssertEqual(vm.splitOutputPageCount, 3); XCTAssertTrue(vm.currentPreviewPageIsIncluded)
        vm.splitPreview.goToPage(3); try await ready(vm.splitPreview)
        XCTAssertFalse(vm.currentPreviewPageIsIncluded)
        XCTAssertNotEqual(vm.splitPreview.image?.tiffRepresentation, firstImage)
        vm.execute(); try await finish(vm)
        XCTAssertEqual(vm.results.count, 2)
        XCTAssertEqual(vm.results.map { PDFDocument(url: $0.outputURL)?.pageCount }, [2, 1])
        XCTAssertTrue(PDFDocument(url: vm.results[1].outputURL)?.page(at: 0)?.string?.contains("PAGE 4") == true)
        let ids = vm.results.map(\.id)
        vm.splitPreview.goToPage(4); try await ready(vm.splitPreview)
        XCTAssertTrue(vm.currentPreviewPageIsIncluded)
        XCTAssertEqual(vm.results.map(\.id), ids, "翻页不应清空拆分结果")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    @MainActor func testInvalidAndEmptyRangesExplainBoundsAndDisableExecution() async throws {
        let source = try pdf("six.pdf", pages: 6)
        let vm = PDFToolsViewModel(); vm.selectedTool = .split; vm.addFiles(from: [source])
        XCTAssertFalse(vm.canExecute, "读取页数前不能处理")
        try await ready(vm.splitPreview)
        for range in ["0", "7", "1-7", "3-2", "abc", "1,"] {
            vm.splitRangesText = range
            XCTAssertFalse(vm.canExecute, range)
            XCTAssertTrue(vm.splitRangeError?.contains("文档共 6 页") == true, range)
            XCTAssertTrue(vm.splitPreviewRanges.isEmpty, range)
        }
        vm.splitRangesText = "   "
        XCTAssertNil(vm.splitRangeError); XCTAssertFalse(vm.canExecute)
        vm.splitRangesText = "1–2，6"
        XCTAssertNil(vm.splitRangeError); XCTAssertTrue(vm.canExecute)
        XCTAssertEqual(vm.splitOutputPageCount, 3)
    }

    @MainActor func testJumpRejectsInvalidPagesAndLatestRapidPageRequestWins() async throws {
        let preview = PDFSplitPreviewViewModel(); preview.select(try pdf("pages.pdf", pages: 5))
        try await ready(preview)
        for value in ["0", "6", "abc", ""] {
            preview.jump(to: value); XCTAssertNotNil(preview.jumpError); XCTAssertEqual(preview.currentPage, 1)
        }
        preview.goToPage(2); preview.goToPage(3); preview.jump(to: " 5 ")
        try await ready(preview)
        XCTAssertEqual(preview.currentPage, 5); XCTAssertNotNil(preview.image); XCTAssertNil(preview.jumpError)
        let finalImage = preview.image?.tiffRepresentation
        preview.goToPage(6); try await ready(preview)
        XCTAssertEqual(preview.currentPage, 5); XCTAssertEqual(preview.image?.tiffRepresentation, finalImage)
    }

    @MainActor func testSwitchingDocumentsCannotApplyStalePageCountOrImage() async throws {
        let first = try pdf("first.pdf", pages: 8), second = try pdf("second.pdf", pages: 2)
        let preview = PDFSplitPreviewViewModel()
        preview.select(first); preview.select(second); try await ready(preview)
        XCTAssertEqual(preview.selectedURL, second); XCTAssertEqual(preview.pageCount, 2)
        XCTAssertEqual(preview.currentPage, 1); XCTAssertNotNil(preview.image)
        preview.goToPage(2); preview.select(first); preview.select(second); try await ready(preview)
        XCTAssertEqual(preview.selectedURL, second); XCTAssertEqual(preview.pageCount, 2); XCTAssertEqual(preview.currentPage, 1)
    }

    @MainActor func testMultipleDocumentsPreviewSeparatelyButSplitRequiresOneAndRemovalRefreshes() async throws {
        let first = try pdf("first.pdf", pages: 3), second = try pdf("second.pdf", pages: 7)
        let vm = PDFToolsViewModel(); vm.selectedTool = .split; vm.addFiles(from: [first, second]); try await ready(vm.splitPreview)
        XCTAssertEqual(vm.splitPreview.selectedURL, first); XCTAssertEqual(vm.splitPreview.pageCount, 3)
        vm.splitRangesText = "1-2"
        XCTAssertFalse(vm.canExecute); XCTAssertTrue(vm.splitRangeError?.contains("一份 PDF") == true)
        vm.splitPreview.select(second); try await ready(vm.splitPreview)
        XCTAssertEqual(vm.splitPreview.pageCount, 7); XCTAssertFalse(vm.canExecute)
        vm.removeFile(url: second); try await ready(vm.splitPreview)
        XCTAssertEqual(vm.splitPreview.selectedURL, first); XCTAssertEqual(vm.splitPreview.pageCount, 3)
        XCTAssertTrue(vm.canExecute)
        vm.clearFiles(); try await ready(vm.splitPreview)
        XCTAssertNil(vm.splitPreview.selectedURL); XCTAssertNil(vm.splitPreview.pageCount); XCTAssertNil(vm.splitPreview.image)
        XCTAssertFalse(vm.canExecute)
    }

    @MainActor func testCorruptLockedAndRemovedDocumentsClearOldPreviewAndShowErrors() async throws {
        let valid = try pdf("valid.pdf", pages: 2)
        let locked = directory.appendingPathComponent("locked.pdf")
        try PDFService().encrypt(url: valid, config: EncryptionConfig(userPassword: "qa-password", ownerPassword: "qa-owner", allowPrinting: true, allowCopying: true), outputURL: locked)
        let corrupt = directory.appendingPathComponent("corrupt.pdf"); try Data("broken".utf8).write(to: corrupt)
        let removed = directory.appendingPathComponent("removed.pdf")
        let preview = PDFSplitPreviewViewModel(); preview.select(valid); try await ready(preview)
        XCTAssertNotNil(preview.image)
        for source in [locked, corrupt, removed] {
            preview.select(source); try await ready(preview)
            XCTAssertNil(preview.pageCount); XCTAssertNil(preview.image)
            XCTAssertNotNil(preview.documentError); XCTAssertFalse(preview.isReady)
        }
        preview.select(nil); try await ready(preview); XCTAssertNil(preview.documentError)
    }

    @MainActor func testChangedDocumentBlocksStalePreviewAndReloadUpdatesPageCount() async throws {
        let source = try pdf("changed.pdf", pages: 3)
        let vm = PDFToolsViewModel(); vm.selectedTool = .split; vm.addFiles(from: [source]); try await ready(vm.splitPreview)
        vm.splitRangesText = "1-3"; XCTAssertTrue(vm.canExecute)
        _ = try pdf("changed.pdf", pages: 1)
        XCTAssertFalse(vm.canExecute)
        vm.execute(); XCTAssertTrue(vm.errorMessage?.contains("文件已变化") == true)
        vm.splitPreview.goToPage(2); try await ready(vm.splitPreview)
        XCTAssertTrue(vm.splitPreview.documentError?.contains("文件已变化") == true)
        XCTAssertNil(vm.splitPreview.image)
        vm.splitPreview.reload(); try await ready(vm.splitPreview)
        XCTAssertEqual(vm.splitPreview.pageCount, 1); XCTAssertNotNil(vm.splitPreview.image)
        XCTAssertNil(vm.splitPreview.documentError); XCTAssertFalse(vm.canExecute)
        XCTAssertTrue(vm.splitRangeError?.contains("文档共 1 页") == true)
        XCTAssertTrue(vm.splitRangeError?.contains("例如 1。") == true)
        vm.splitRangesText = "1"; XCTAssertTrue(vm.canExecute)
    }

    @MainActor func testClearingWhileLoadingCannotRestoreRemovedDocument() async throws {
        let preview = PDFSplitPreviewViewModel(); preview.select(try pdf("many.pdf", pages: 40))
        preview.setFiles([])
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(preview.selectedURL); XCTAssertNil(preview.pageCount); XCTAssertNil(preview.image)
        XCTAssertFalse(preview.isLoadingDocument); XCTAssertFalse(preview.isRenderingPage)
    }
}
