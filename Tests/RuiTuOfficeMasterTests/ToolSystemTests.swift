import XCTest
import Foundation
import AppKit
import PDFKit
import ImageIO
import CoreText
import UniformTypeIdentifiers
@testable import RuiTuOfficeMaster

final class ToolSystemTests: XCTestCase, @unchecked Sendable {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rito-tools-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url
    }
    private func image(_ url: URL) throws {
        let ctx = try XCTUnwrap(CGContext(data:nil,width:64,height:48,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed:0.2,green:0.6,blue:0.9,alpha:1));ctx.fill(CGRect(x:0,y:0,width:64,height:48))
        let img = try XCTUnwrap(ctx.makeImage())
        try ImageCodec.encode(img,type:.png,quality:1).write(to:url)
    }
    private func pdf(_ url: URL, pages: Int = 3) throws {
        var rect = CGRect(x:0,y:0,width:200,height:280)
        let ctx = try XCTUnwrap(CGContext(url as CFURL,mediaBox:&rect,nil))
        for i in 0..<pages {
            ctx.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:"Rito fixture page \(i)",attributes:[.font:NSFont.systemFont(ofSize:16)]) as CFAttributedString)
            ctx.textPosition = CGPoint(x:20,y:100);CTLineDraw(line,ctx);ctx.endPDFPage()
        }
        ctx.closePDF()
    }
    private func attached(_ url: URL, id: UUID) -> RToolAIAttachment { .init(id:id,name:url.lastPathComponent,byteCount:0,isDirectory:false) }
    private func raw(_ operation: String, id: UUID, extra: [String:Any] = [:]) throws -> String {
        var call: [String:Any] = ["operation":operation,"attachmentIDs":[id.uuidString]]
        for (k,v) in extra { call[k] = v }
        return String(decoding:try JSONSerialization.data(withJSONObject:["message":"test","task":call]),as:UTF8.self)
    }
    func testEveryNativeOperationHasUniqueRegistryAndConfirmation() {
        XCTAssertEqual(Set(ToolRegistry.tools.map(\.operation)),Set(RitoToolCall.Operation.allCases))
        XCTAssertEqual(ToolRegistry.tools.count,24)
        XCTAssertEqual(Set(ToolRegistry.tools.map(\.id)).count,24)
        XCTAssertTrue(ToolRegistry.tools.allSatisfy(\.requiresConfirmation))
        XCTAssertEqual(ToolRegistry.lookup(.file_rename).risk,.changesOriginals)
        XCTAssertEqual(ToolRegistry.lookup(.organize_move).risk,.changesOriginals)
    }
    func testUnknownKeysCommandsPathsAndSecretsRejected() throws {
        let id = UUID(), file = RToolAIAttachment(id:UUID(),name:"photo.png",byteCount:1)
        let matching = RToolAIAttachment(id:id,name:file.name,byteCount:1)
        let invalids: [[String:Any]] = [["command":"rm"],["path":"/tmp/x"],["regionConfirmed":true],["parameters":["shell":"rm"]],["parameters":["password":"secret"]]]
        for extra in invalids {
            XCTAssertThrowsError(try RitoToolCall.decode(raw("image_convert",id:id,extra:extra),attachments:[matching]))
        }
        XCTAssertThrowsError(try RitoToolCall.decode(raw("run_shell",id:id),attachments:[matching]))
    }
    func testParametersValidateBoundsAndLegacyCallsStillDecode() throws {
        let id = UUID(), image = RToolAIAttachment(id:id,name:"photo.png",byteCount:1)
        let parsed = try RitoToolCall.decode(raw("image_resize",id:id,extra:["parameters":["width":32,"height":24,"format":"jpg"]]),attachments:[image]).1
        XCTAssertEqual(parsed?.parameters?["width"],"32")
        for width in ["nan","inf","-2","20000","2.5"] {
            XCTAssertThrowsError(try RitoToolCall.decode(raw("image_resize",id:id,extra:["parameters":["width":width,"height":"24"]]),attachments:[image]))
        }
        XCTAssertEqual(try RitoToolCall.decode(raw("ocr",id:id),attachments:[image]).1?.operation,.ocr)
        XCTAssertThrowsError(try RitoToolCall.decode(raw("video_compress",id:id),attachments:[image]))
    }
    func testChainRejectsWrongTypesMutationsAndOversizedDependencies() throws {
        let id = UUID()
        XCTAssertThrowsError(try TaskEngine.validateChain(.init(operation:.image_convert,attachmentIDs:[id],following:[.init(operation:.pdf_split,parameters:["ranges":"1"])])))
        XCTAssertThrowsError(try TaskEngine.validateChain(.init(operation:.image_convert,attachmentIDs:[id],following:[.init(operation:.file_rename,parameters:["text":"x"])])))
        XCTAssertThrowsError(try TaskEngine.validateChain(.init(operation:.image_convert,attachmentIDs:[id],following:Array(repeating:.init(operation:.image_convert),count:4))))
        XCTAssertNoThrow(try TaskEngine.validateChain(.init(operation:.image_convert,attachmentIDs:[id],following:[.init(operation:.image_resize,parameters:["width":"32","height":"32"])])))
    }
    func testConversionThenResizeProducesRealFilesAndRetainsOriginal() async throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("photo.png"), output = dir.appendingPathComponent("out"), id = UUID()
        try image(input);let original = try Data(contentsOf:input)
        let call = RitoToolCall(operation:.image_convert,attachmentIDs:[id],parameters:["format":"jpg"],following:[.init(operation:.image_resize,parameters:["width":"32","height":"32","format":"png"])])
        let prepared = try await TaskEngine.prepare(call,files:[id:input],destination:output)
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        let results = try await TaskEngine.execute(prepared) { _ in }
        let file = try XCTUnwrap(results.first?.fileReference).resolvedURL()
        XCTAssertEqual(file.pathExtension,"png")
        XCTAssertEqual(try ImageCodec.dimensions(at:file),CGSize(width:32,height:24))
        XCTAssertEqual(try Data(contentsOf:input),original)
        XCTAssertTrue(FileManager.default.fileExists(atPath:output.appendingPathComponent("1_photo_图片格式转换.jpg").path))
    }
    func testRenamePreviewExecutionAndVersionSafeUndo() async throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("a.txt"),id = UUID();try Data("original".utf8).write(to:input)
        let call = RitoToolCall(operation:.file_rename,attachmentIDs:[id],parameters:["mode":"prefix","text":"合同_"])
        let prepared = try await TaskEngine.prepare(call,files:[id:input],destination:nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath:input.path))
        let results = try await TaskEngine.execute(prepared) { _ in }
        let move = try XCTUnwrap(results.first?.renameRecovery)
        XCTAssertEqual(move.renamed.lastPathComponent,"合同_a.txt")
        XCTAssertEqual(try Data(contentsOf:move.renamed),Data("original".utf8))
        switch FileRenameService().undo([move]) { case .success: break; case .failure: XCTFail("Undo failed") }
        XCTAssertEqual(try Data(contentsOf:input),Data("original".utf8))
    }
    private final class StopCounter: @unchecked Sendable {
        let lock = NSLock();var count = 0
        func stop() -> Bool { lock.lock();defer { lock.unlock() };count += 1;return count > 2 }
    }
    func testCancelledRenameRollsBackStagedNames() throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let files = (0..<5).map { dir.appendingPathComponent("file\($0).txt") }
        for file in files { try Data("source".utf8).write(to:file) }
        let preview = FileRenameService().generatePreview(files:files,mode:.prefix,prefix:"new_",suffix:"",findText:"",replaceText:"",numberText:"",startNumber:1,numberDigits:3)
        let counter = StopCounter()
        switch FileRenameService().execute(previewItems:preview,shouldStop:{ counter.stop() },progressHandler:{ _ in }) {
        case .success: XCTFail("Cancelled rename cannot succeed")
        case .failure: break
        }
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath:$0.path) })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:dir.path).count,5)
    }
    func testChangedSourceAndOccupiedOutputNeverOverwrite() async throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("photo.png"),output = dir.appendingPathComponent("out"),id = UUID()
        try image(input)
        let call = RitoToolCall(operation:.image_convert,attachmentIDs:[id],parameters:["format":"jpg"])
        let prepared = try await TaskEngine.prepare(call,files:[id:input],destination:output)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
        let sentinel = output.appendingPathComponent("keep.txt");try Data("keep".utf8).write(to:sentinel)
        do { _ = try await TaskEngine.execute(prepared) { _ in };XCTFail() } catch { }
        XCTAssertEqual(try Data(contentsOf:sentinel),Data("keep".utf8))
        let next = dir.appendingPathComponent("next")
        let changed = try await TaskEngine.prepare(call,files:[id:input],destination:next)
        try Data("broken-source".utf8).write(to:input)
        do { _ = try await TaskEngine.execute(changed) { _ in };XCTFail() } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath:next.path))
    }
    func testPDFSplitThenMergeRetainsPagesAndOriginal() async throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("a.pdf"),output = dir.appendingPathComponent("out"),id = UUID()
        try pdf(input);let original = try Data(contentsOf:input)
        let call = RitoToolCall(operation:.pdf_split,attachmentIDs:[id],parameters:["ranges":"1-2,3"],following:[.init(operation:.pdf_merge)])
        let prepared = try await TaskEngine.prepare(call,files:[id:input],destination:output)
        XCTAssertTrue(prepared.summary.contains { $0.contains("总页数：3") })
        let results = try await TaskEngine.execute(prepared) { _ in }
        let file = try XCTUnwrap(results.first?.fileReference).resolvedURL()
        XCTAssertEqual(PDFDocument(url:file)?.pageCount,3)
        XCTAssertEqual(try Data(contentsOf:input),original)
    }
    func testPDFEncryptionWorksAndPasswordNeverEntersHistory() async throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("a.pdf"),output = dir.appendingPathComponent("out"),id = UUID()
        try pdf(input)
        let call = RitoToolCall(operation:.pdf_encrypt,attachmentIDs:[id])
        let secret = "fixture-open"
        let owner = "unit-test-only-owner"
        let prepared = try await TaskEngine.prepare(call,files:[id:input],destination:output,password:secret,localOptions:.init(ownerPassword:owner))
        XCTAssertFalse(prepared.summary.joined().contains(secret))
        XCTAssertFalse(prepared.summary.joined().contains(owner))
        let results = try await TaskEngine.execute(prepared) { _ in }
        let file = try XCTUnwrap(results.first?.fileReference).resolvedURL()
        let encrypted = try XCTUnwrap(PDFDocument(url:file));XCTAssertTrue(encrypted.isLocked)
        XCTAssertTrue(encrypted.unlock(withPassword:secret));XCTAssertEqual(encrypted.pageCount,3)
        let privileged = try XCTUnwrap(PDFDocument(data:Data(contentsOf:file)))
        XCTAssertTrue(privileged.unlock(withPassword:owner))
        XCTAssertEqual(privileged.permissionsStatus,.owner)
        let plan = RToolAITaskPlan(id:UUID(),intent:.pdfDocument,sourceNames:[input.lastPathComponent],results:results,liveCall:call)
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(plan),as:UTF8.self).contains(secret))
        XCTAssertFalse(String(decoding:try JSONEncoder().encode(plan),as:UTF8.self).contains(owner))
    }
    func testExactResizeUsesTheSameParametersInPreviewAndOutput() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("image.png"), id = UUID()
        try image(input)
        let call = RitoToolCall(operation:.image_resize,attachmentIDs:[id],parameters:["sizeMode":"exact","width":"32","height":"16"])
        let plan = try await TaskEngine.prepare(call,files:[id:input],destination:dir.appendingPathComponent("out"))
        XCTAssertTrue(plan.summary.contains("尺寸方式：自定义宽高"))
        let files = try await TaskEngine.execute(plan) { _ in }
        let output = try XCTUnwrap(files.first?.fileReference).resolvedURL()
        XCTAssertEqual(try ImageCodec.dimensions(at:output),CGSize(width:32,height:16))
    }
    func testOrganizerOptionsChangePreviewAndHonorExcludedFolder() async throws {
        let dir = try root(); defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("input"), excluded = input.appendingPathComponent("exclude")
        try FileManager.default.createDirectory(at:excluded,withIntermediateDirectories:true)
        try Data("one".utf8).write(to:input.appendingPathComponent("one.txt"))
        try Data("two".utf8).write(to:excluded.appendingPathComponent("two.txt"))
        let id = UUID(), out = dir.appendingPathComponent("out")
        var call = RitoToolCall(operation:.organize_copy,attachmentIDs:[id],parameters:["recursive":"false","conflict":"skip"])
        let shallow = try await TaskEngine.prepare(call,files:[id:input],destination:out)
        XCTAssertEqual(shallow.organizer?.items.count,1)
        XCTAssertTrue(shallow.summary.contains("同名文件：跳过同名"))
        call.parameters?["recursive"] = "true"
        let plan = try await TaskEngine.prepare(call,files:[id:input],destination:out,localOptions:.init(exclusions:[excluded]))
        XCTAssertEqual(plan.organizer?.items.map { $0.source.lastPathComponent },["one.txt"])
        XCTAssertTrue(plan.summary.contains("排除目录：1 个"))
    }
    func testCustomIDPhotoSizeColorAndDPIUseNativeSettings() throws {
        let tool = ToolRegistry.lookup(.id_photo)
        let values = try tool.values(["preset":"custom","widthMM":"30","heightMM":"40","dpi":"600","background":"custom","red":"0.3","green":"0.4","blue":"0.5"])
        let settings = TaskEngine.photoSettings(values)
        XCTAssertEqual(settings.pixelSize,CGSize(width:709,height:945))
        XCTAssertEqual(settings.red,0.3)
        XCTAssertEqual(settings.green,0.4)
        XCTAssertEqual(settings.blue,0.5)
        XCTAssertTrue(tool.parameterSummary(values).contains("分辨率（DPI）：600"))
    }
    func testWatermarkRegionRequiresLocalConfirmationAndOnlyRepairsSelection() async throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("a.png"),output = dir.appendingPathComponent("out"),id = UUID()
        try image(input);let original = try Data(contentsOf:input)
        var call = RitoToolCall(operation:.watermark_remove,attachmentIDs:[id],parameters:["x":"0.2","y":"0.2","width":"0.2","height":"0.2","method":"surrounding"])
        do { _ = try await TaskEngine.prepare(call,files:[id:input],destination:output);XCTFail() } catch { }
        call.regionConfirmed = true
        let prepared = try await TaskEngine.prepare(call,files:[id:input],destination:output)
        let results = try await TaskEngine.execute(prepared) { _ in }
        XCTAssertNotNil(results.first?.fileReference)
        XCTAssertEqual(try Data(contentsOf:input),original)
    }
    func testIDPhotoOriginalBackgroundAndPrintUseExistingService() async throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("a.png"),id = UUID();try image(input)
        let call = RitoToolCall(operation:.id_photo_print,attachmentIDs:[id],parameters:["background":"original","preset":"one","paper":"a4"])
        let prepared = try await TaskEngine.prepare(call,files:[id:input],destination:dir.appendingPathComponent("out"))
        XCTAssertLessThanOrEqual(prepared.previewData?.count ?? 0,RitoImagePreview.byteLimit)
        let results = try await TaskEngine.execute(prepared) { _ in }
        let file = try XCTUnwrap(results.first?.fileReference).resolvedURL()
        XCTAssertEqual(PDFDocument(url:file)?.pageCount,1)
    }
    func testCloudContextExcludesTaskParametersPathsRecoveryAndImagePreviews() throws {
        let id = UUID()
        let file = RitoResultFile(url:URL(fileURLWithPath:"/PRIVATE/result.png"))
        let result = RToolAIResult(sourceName:"PRIVATE.png",detail:"PRIVATE result",fileReference:file)
        let call = RitoToolCall(operation:.pdf_watermark,attachmentIDs:[id],parameters:["text":"PRIVATE parameter"])
        let message = RToolAIMessage(id:UUID(),role:.assistant,text:"public message",task:.init(id:UUID(),intent:.plan,sourceNames:["private"],results:[result],liveCall:call),source:.custom)
        let request = RToolAIRequest(messages:[message],text:"hello",attachments:[],intent:nil,toolInstructions:"registered tools only")
        let context = try RitoConversationContext.messages(request)
        let encoded = String(decoding:try JSONSerialization.data(withJSONObject:context),as:UTF8.self)
        XCTAssertFalse(encoded.contains("PRIVATE"));XCTAssertTrue(encoded.contains("registered tools only"))
    }
    func testChainRejectsFileCountMismatchBeforeAnyExecution() throws {
        XCTAssertThrowsError(try TaskEngine.validateChain(.init(operation:.image_convert,attachmentIDs:[UUID(),UUID()],following:[.init(operation:.id_photo)])))
        XCTAssertThrowsError(try TaskEngine.validateChain(.init(operation:.pdf_watermark,attachmentIDs:[UUID()],parameters:["text":"test"],following:[.init(operation:.pdf_merge)])))
        XCTAssertTrue(ToolRegistry.prompt(for:[]).contains("video_compress"))
        let local = ToolRegistry.localPrompt(for:[.init(id:UUID(),name:"a.png",byteCount:1)],text:"给照片换蓝色背景")
        XCTAssertTrue(local.contains("id_photo:background="))
        XCTAssertLessThan(local.utf8.count,5000)
    }
    func testPDFWatermarkAndDocumentRoundTripUseNativeAdapters() async throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let input = dir.appendingPathComponent("a.pdf"),img = dir.appendingPathComponent("mark.png"),id = UUID(),imageID = UUID()
        try pdf(input);try image(img);let original = try Data(contentsOf:input)
        for op in [RitoToolCall.Operation.pdf_watermark,.pdf_image_watermark] {
            let call = RitoToolCall(operation:op,attachmentIDs:op == .pdf_watermark ? [id] : [id,imageID],parameters:op == .pdf_watermark ? ["text":"Rito fixture"] : [:])
            let prepared = try await TaskEngine.prepare(call,files:[id:input,imageID:img],destination:dir.appendingPathComponent(op.rawValue))
            let results = try await TaskEngine.execute(prepared) { _ in }
            let file = try XCTUnwrap(results.first?.fileReference).resolvedURL()
            XCTAssertEqual(PDFDocument(url:file)?.pageCount,3)
        }
        let call = RitoToolCall(operation:.pdf_to_word,attachmentIDs:[id],following:[.init(operation:.word_to_pdf)])
        let plan = try await TaskEngine.prepare(call,files:[id:input],destination:dir.appendingPathComponent("roundtrip"))
        let results = try await TaskEngine.execute(plan) { _ in }
        let output = try XCTUnwrap(results.first?.fileReference).resolvedURL()
        XCTAssertTrue(PDFDocument(url:output)?.string?.contains("Rito fixture page 0") == true)
        XCTAssertEqual(try Data(contentsOf:input),original)
    }
    func testGIFAdapterProducesRealFramesAndKeepsSource() async throws {
        let dir = try root();defer { try? FileManager.default.removeItem(at:dir) }
        let png = dir.appendingPathComponent("p.png"),gif = dir.appendingPathComponent("a.gif"),id = UUID()
        try image(png)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL,nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source,0,nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(gif as CFURL,UTType.gif.identifier as CFString,4,nil))
        for _ in 0..<4 { CGImageDestinationAddImage(destination,frame,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1]] as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination));let original = try Data(contentsOf:gif)
        let prepared = try await TaskEngine.prepare(.init(operation:.gif_compress,attachmentIDs:[id],parameters:["maxDimension":"32","frameSkip":"2"]),files:[id:gif],destination:dir.appendingPathComponent("out"))
        let results = try await TaskEngine.execute(prepared) { _ in }
        let output = try XCTUnwrap(results.first?.fileReference).resolvedURL()
        let generated = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL,nil))
        XCTAssertEqual(CGImageSourceGetCount(generated),2)
        XCTAssertEqual(try ImageCodec.dimensions(at:output),CGSize(width:32,height:24))
        XCTAssertEqual(try Data(contentsOf:gif),original)
    }
    func testRenameUndoCannotRunAlongsideAnotherTool() async throws {
        let entered = await ToolExecutionGate.shared.enter()
        XCTAssertTrue(entered)
        let result = await TaskEngine.undoRename([])
        await ToolExecutionGate.shared.leave()
        switch result { case .success: XCTFail("Undo must not bypass the execution gate"); case .failure(let errors): XCTAssertFalse(errors.isEmpty) }
    }
}
