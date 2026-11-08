import XCTest
import PDFKit
import CoreGraphics
@testable import RuiTuOfficeMaster

final class RitoPDFSplitParameterTests: XCTestCase {
    func testPlannerExplanationsCannotBecomeEditablePageRanges() {
        XCTAssertEqual(PDFSplitSelection.editableText("待用户在本机补充，例如 1-3,4-6 或每页拆分"),"")
        XCTAssertEqual(PDFSplitSelection.editableText("每页拆分"),"")
        XCTAssertEqual(PDFSplitSelection.editableText("1-2，4"),"1-2，4")
        // Valid syntax must be retained so actual document bounds can explain the error.
        XCTAssertEqual(PDFSplitSelection.editableText("4"),"4")
        let selection = PDFSplitSelection(text:"4",pageCount:3)
        XCTAssertFalse(selection.isValid);XCTAssertTrue(selection.ranges.isEmpty)
        XCTAssertTrue(selection.error?.contains("文档共 3 页") == true)
    }

    func testSaveRequiresKnownPageCountAndValidBoundedRanges() {
        XCTAssertFalse(PDFSplitSelection(text:"1",pageCount:nil).isValid)
        for text in ["", "0", "5", "1-5", "3-2", "1,", "待补充"] {
            XCTAssertFalse(PDFSplitSelection(text:text,pageCount:4).isValid,text)
        }
        let selection = PDFSplitSelection(text:"1-2,2-3",pageCount:4)
        XCTAssertEqual(selection.ranges,[.init(start:1,end:2),.init(start:2,end:3)])
        XCTAssertEqual(selection.totalPages,4,"Overlapping pages count in each output document")
    }

    @MainActor func testDisplayedPageCountAndSelectedGroupsMatchNativeSplitOutputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("preview.pdf")
        var rect = CGRect(x:0,y:0,width:200,height:280)
        let context = try XCTUnwrap(CGContext(source as CFURL,mediaBox:&rect,nil))
        for page in 1...4 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray:CGFloat(page)/5,alpha:1))
            context.fill(CGRect(x:10,y:10,width:100,height:100));context.endPDFPage()
        }
        context.closePDF()
        let original = try Data(contentsOf:source)
        let preview = PDFSplitPreviewViewModel()
        preview.select(source)
        let deadline = ContinuousClock.now.advanced(by:.seconds(10))
        while (preview.isLoadingDocument || preview.isRenderingPage) && ContinuousClock.now < deadline {
            try await Task.sleep(for:.milliseconds(10))
        }
        XCTAssertEqual(preview.pageCount,4);XCTAssertNotNil(preview.image)
        let selection = PDFSplitSelection(text:"2-3,4",pageCount:preview.pageCount)
        XCTAssertTrue(selection.isValid);XCTAssertEqual(selection.totalPages,3)
        preview.goToPage(try XCTUnwrap(selection.ranges.first?.start))
        while preview.isRenderingPage && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(preview.currentPage,2);XCTAssertNotNil(preview.image)
        let outputs = try PDFService().split(url:source,ranges:selection.ranges,outputDir:root.appendingPathComponent("out"))
        XCTAssertEqual(outputs.map { PDFDocument(url:$0)?.pageCount },[2,1])
        XCTAssertEqual(try Data(contentsOf:source),original)
        preview.select(nil)
        XCTAssertNil(preview.pageCount);XCTAssertNil(preview.image)
    }
}
