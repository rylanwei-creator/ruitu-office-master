import XCTest
import Foundation
import CoreGraphics
@testable import RuiTuOfficeMaster

final class RitoRuntimeRecoveryTests: XCTestCase, @unchecked Sendable {
    private struct ConversionPlanner: AIProvider {
        var source: RitoReplySource { .custom }
        var capabilities: AIProviderCapabilities { .init() }
        func reply(to request: RToolAIRequest) async throws -> RToolAIReply {
            let call = RitoToolCall(operation:.image_convert,attachmentIDs:request.attachments.map(\.id),parameters:["format":"jpg"])
            return .init(text:"确认后转换",task:.init(id:UUID(),intent:.extractText,sourceNames:request.attachments.map(\.name),liveCall:call))
        }
    }
    @MainActor private func settle(_ vm: RToolAIViewModel) async throws {
        for _ in 0..<1000 where vm.isBusy { try await Task.sleep(for:.milliseconds(5)) }
        XCTAssertFalse(vm.isBusy)
    }
    @MainActor func testNativeConfirmationProgressCompletesWithoutExclusivityCrash() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source = root.appendingPathComponent("fixture.png")
        let context = try XCTUnwrap(CGContext(data:nil,width:64,height:48,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray:0.6,alpha:1));context.fill(CGRect(x:0,y:0,width:64,height:48))
        let original = try ImageCodec.encode(XCTUnwrap(context.makeImage()),type:.png,quality:1)
        try original.write(to:source)
        let vm = RToolAIViewModel(responder:ConversionPlanner(),destinationPicker:{ root })
        vm.addAttachments([source]);vm.draft = "转JPG";vm.send();try await settle(vm)
        let id = try XCTUnwrap(vm.messages.last?.task?.id)
        vm.confirm(id);try await settle(vm)
        XCTAssertEqual(vm.messages.last?.task?.previewReady,true)
        let path = try XCTUnwrap(vm.outputPath(for:id))
        XCTAssertFalse(FileManager.default.fileExists(atPath:path),"Preview cannot write output")
        vm.confirm(id);vm.confirm(id);try await settle(vm)
        let plan = try XCTUnwrap(vm.messages.last?.task)
        XCTAssertEqual(plan.state,.completed);XCTAssertEqual(plan.progress,1)
        let result = try XCTUnwrap(plan.results.first?.fileReference).resolvedURL()
        XCTAssertEqual(result.pathExtension,"jpg")
        XCTAssertEqual(try ImageCodec.dimensions(at:result),CGSize(width:64,height:48))
        XCTAssertEqual(try Data(contentsOf:source),original)
        vm.confirm(id);XCTAssertFalse(vm.isBusy)
    }
    @MainActor func testCancellingDestinationPickerReleasesTaskAndMascot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try Data([1]).write(to:root);defer { try? FileManager.default.removeItem(at:root) }
        let vm = RToolAIViewModel(responder:ConversionPlanner(),destinationPicker:{ nil })
        vm.addAttachments([root]);vm.draft = "转JPG";vm.send();try await settle(vm)
        vm.confirm(try XCTUnwrap(vm.messages.last?.task?.id));try await settle(vm)
        XCTAssertNil(vm.currentToolID);XCTAssertEqual(vm.messages.last?.task?.state,.awaitingConfirmation)
    }
    private actor RecoveryTransport: RitoStreamingTransport {
        let code: URLError.Code
        let failAfterHeaders: Bool
        var attempts = 0
        init(code:URLError.Code = .networkConnectionLost,failAfterHeaders:Bool = false) {
            self.code = code;self.failAfterHeaders = failAfterHeaders
        }
        func count() -> Int { attempts }
        func open(_ request:URLRequest) async throws -> (AsyncThrowingStream<Data,Error>,Int) {
            attempts += 1
            if attempts == 1 {
                if failAfterHeaders {
                    return (.init { c in
                        c.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"部分回答\"}}]}\n\n".utf8))
                        c.finish(throwing:URLError(code))
                    },200)
                }
                throw URLError(code)
            }
            return (.init { c in
                c.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"回答成功\"},\"finish_reason\":\"stop\"}]}\n\n".utf8));c.finish()
            },200)
        }
    }
    private func input() -> RToolAIRequest { .init(messages:[],text:"你好",attachments:[],intent:nil) }
    private func provider(_ transport:any RitoStreamingTransport) -> RitoCustomAPIProvider {
        .init(endpoint:URL(string:"https://fixture.example/chat/completions")!,authorization:"fixture-only",model:"test",transport:transport)
    }
    @MainActor func testTransientConnectFailureReconnectsOnceBeforeResponse() async throws {
        let transport = RecoveryTransport()
        var request = input(), phases:[RitoConnectionPhase] = []
        request.progress = { phases.append($0) }
        let reply = try await provider(transport).reply(to:request)
        XCTAssertEqual(reply.text,"回答成功");let count = await transport.count();XCTAssertEqual(count,2)
        XCTAssertTrue(phases.contains { if case .reconnecting = $0 { true } else { false } })
    }
    @MainActor func testPartialAnswerIsNotAutomaticallyReplayedAndFailureStaysWithMessage() async throws {
        let transport = RecoveryTransport(failAfterHeaders:true)
        let vm = RToolAIViewModel(responder:provider(transport))
        vm.draft = "你好";vm.send();try await settle(vm)
        XCTAssertEqual(vm.messages.last?.text,"部分回答")
        XCTAssertTrue(vm.messages.first?.replyIssue?.contains("已保留部分文字") == true)
        let count = await transport.count();XCTAssertEqual(count,1)
        XCTAssertFalse(vm.canRetryReply)
    }
    func testTimeoutIsNotAutomaticallyReplayed() async throws {
        let transport = RecoveryTransport(code:.timedOut)
        do { _ = try await provider(transport).reply(to:input());XCTFail() }
        catch { XCTAssertEqual(error as? RitoCloudError,.timeout) }
        let count = await transport.count();XCTAssertEqual(count,1)
    }
    private actor EmptyThenAnswer: RitoStreamingTransport {
        let alwaysEmpty: Bool
        var bodies: [[String:Any]] = []
        init(alwaysEmpty:Bool = false) { self.alwaysEmpty = alwaysEmpty }
        func snapshots() -> (Int,[Bool],[Int]) {
            (bodies.count,bodies.map { $0["response_format"] != nil },bodies.map { ($0["messages"] as? [Any])?.count ?? 0 })
        }
        func open(_ request:URLRequest) async throws -> (AsyncThrowingStream<Data,Error>,Int) {
            bodies.append(try JSONSerialization.jsonObject(with:request.httpBody!) as! [String:Any])
            let empty = alwaysEmpty || bodies.count == 1
            let payload = try JSONSerialization.data(withJSONObject:["choices":[["delta":["content":empty ? "   " : "兼容回答成功"],"finish_reason":"stop"]]])
            let event = Data("data: ".utf8) + payload + Data("\n\n".utf8)
            return (.init { c in
                c.yield(event)
                c.finish()
            },200)
        }
    }
    func testEmptyJSONReplyRetriesOnceWithoutForcedJSONAndStalePlanHistory() async throws {
        let transport = EmptyThenAnswer()
        let provider = RitoCustomAPIProvider(endpoint:URL(string:"https://api.deepseek.com/chat/completions")!,model:"fixture",transport:transport)
        var request = RToolAIRequest(messages:[.init(id:UUID(),role:.assistant,text:"old plan",source:.custom)],
            text:"换成红底",attachments:[],intent:nil,toolInstructions:"Return JSON only.")
        request.expectsToolPlan = true
        let reply = try await provider.reply(to:request)
        XCTAssertEqual(reply.text,"兼容回答成功")
        let (count,formats,contexts) = await transport.snapshots()
        XCTAssertEqual(count,2);XCTAssertEqual(formats,[true,false]);XCTAssertEqual(contexts,[3,2])
    }
    @MainActor func testTwoEmptyRepliesStopAndPreserveOneUserRequestForManualRetry() async throws {
        let transport = EmptyThenAnswer(alwaysEmpty:true)
        let vm = RToolAIViewModel(responder:provider(transport))
        vm.draft = "你好";vm.send();try await settle(vm)
        let (count,_,_) = await transport.snapshots();XCTAssertEqual(count,2)
        XCTAssertEqual(vm.messages.count,1);XCTAssertTrue(vm.canRetryReply)
        XCTAssertTrue(vm.messages.first?.replyIssue?.contains("没有返回回答正文") == true)
    }
}
