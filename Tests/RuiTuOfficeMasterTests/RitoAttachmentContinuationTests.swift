import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import RuiTuOfficeMaster

@MainActor
final class RitoAttachmentContinuationTests: XCTestCase {
    private actor Planner: AIProvider {
        nonisolated var source: RitoReplySource { .custom }
        private(set) var inputs: [RToolAIRequest] = []
        func reply(to request: RToolAIRequest) async throws -> RToolAIReply {
            inputs.append(request)
            guard request.continuesAttachmentTask, request.text == "就按默认的吧" else {
                return .init(text: request.expectsToolPlan ? "{\"message\":\"默认减少 40%，可以吗？\",\"task\":null}" : "普通回复", task: nil)
            }
            if inputs.count == 2 { return .init(text: "invalid plan", task: nil) }
            let prompt = try XCTUnwrap(request.toolInstructions)
            let range = try XCTUnwrap(prompt.range(of: "[A-F0-9-]{36}", options: .regularExpression))
            let json = """
            {"message":"将按默认值压缩","task":{"operation":"image_compress","attachmentIDs":["\(prompt[range])"],"parameters":{"reduction":"0.4","format":"jpg"}}}
            """
            return .init(text: json, task: nil)
        }
    }

    private func settle(_ model: RToolAIViewModel) async throws {
        for _ in 0..<500 {
            if !model.isBusy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Reply or local tool did not finish")
    }

    func testSupplementReusesAuthorizedImageThroughRepairPreviewAndExecution() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("private-portrait.png")
        let ctx = try XCTUnwrap(CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<32 { for y in 0..<32 {
            let hue = CGFloat((x * 51 + y * 107) % 257) / 256
            ctx.setFillColor(CGColor(red: hue, green: 1 - hue, blue: 0.5, alpha: 1))
            ctx.fill(CGRect(x: x * 4, y: y * 4, width: 4, height: 4))
        } }
        let original = try ImageCodec.encode(XCTUnwrap(ctx.makeImage()), type: .png, quality: 1)
        try original.write(to: file)
        let planner = Planner()
        let model = RToolAIViewModel(responder: RitoOfficeProvider(underlying: planner), destinationPicker: { dir })
        model.addAttachments([file]); model.draft = "帮我压缩图片"; model.send()
        try await settle(model)
        let id = try XCTUnwrap(model.continuingAttachments.first?.id)
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertNil(model.messages.last?.task)
        model.draft = "就按默认的吧"; model.send()
        try await settle(model)
        let plan = try XCTUnwrap(model.messages.last?.task)
        XCTAssertEqual(plan.liveCall?.attachmentIDs, [id])
        XCTAssertEqual(model.originalURL(for: plan), file.standardizedFileURL)
        XCTAssertTrue(model.messages.filter { $0.role == .user }.last?.attachments.isEmpty == true)
        XCTAssertTrue(model.continuingAttachments.isEmpty)
        let requests = await planner.inputs
        XCTAssertEqual(requests.count, 3)
        for input in requests.dropFirst() {
            let payload = try RitoConversationContext.messages(input).map { $0["content"] ?? "" }.joined()
            XCTAssertTrue(payload.contains("帮我压缩图片"))
            XCTAssertTrue(payload.contains("默认减少 40%"))
            XCTAssertTrue(payload.contains(id.uuidString))
            XCTAssertFalse(payload.contains(file.lastPathComponent))
            XCTAssertTrue(input.attachments.isEmpty)
        }
        model.confirm(plan.id); try await settle(model)
        let preview = try XCTUnwrap(model.messages.last?.task)
        XCTAssertEqual(preview.previewReady, true)
        XCTAssertTrue(preview.results.isEmpty)
        var edited = try XCTUnwrap(preview.liveCall?.parameters)
        edited["reduction"] = "0.5"
        try model.updateTool(plan.id,parameters:edited,following:[],regionConfirmed:false,password:"",order:[id],localOptions:.init())
        XCTAssertEqual(model.messages.last?.task?.previewReady, false)
        model.confirm(plan.id); try await settle(model)
        XCTAssertEqual(model.messages.last?.task?.previewReady, true)
        XCTAssertTrue(model.messages.last?.task?.previewSummary?.contains("减少比例：减少 50.0%") == true)
        model.confirm(plan.id); try await settle(model)
        XCTAssertEqual(model.messages.last?.task?.state, .completed)
        XCTAssertFalse(model.messages.last?.task?.results.isEmpty ?? true)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testNewChatCannotReuseAnotherChatsAttachmentAndClearDisablesReuse() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let planner = Planner()
        let model = RToolAIViewModel(responder: RitoOfficeProvider(underlying: planner))
        model.addAttachments([file]); model.draft = "处理文件"; model.send()
        try await settle(model)
        let chat = model.conversationID
        model.newConversation()
        XCTAssertTrue(model.continuingAttachments.isEmpty)
        model.draft = "你好"; model.send(); try await settle(model)
        model.openConversation(chat)
        XCTAssertEqual(model.continuingAttachments.count, 1)
        model.clearContinuingAttachments()
        model.draft = "你好"; model.send(); try await settle(model)
        let inputs = await planner.inputs
        XCTAssertEqual(inputs.map(\.expectsToolPlan), [true, false, false])
    }
}
