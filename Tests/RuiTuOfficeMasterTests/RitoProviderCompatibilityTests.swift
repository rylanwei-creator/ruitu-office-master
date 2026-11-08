import XCTest
import Foundation
@testable import RuiTuOfficeMaster

final class RitoProviderCompatibilityTests: XCTestCase, @unchecked Sendable {
    private func input() -> RToolAIRequest { .init(messages:[],text:"test",attachments:[],intent:nil) }
    private struct Fixture: RitoStreamingTransport {
        let body: String
        var status = 200
        func open(_ request:URLRequest) async throws -> (AsyncThrowingStream<Data,Error>,Int) {
            (.init { c in c.yield(Data(body.utf8));c.finish() },status)
        }
    }
    func testDeepSeekRequestsExplicitlyDisableHiddenThinkingAndBoundPlanOutput() throws {
        let provider = RitoCustomAPIProvider(endpoint:URL(string:"https://api.deepseek.com/chat/completions")!,model:"deepseek-chat")
        var plan = input();plan.expectsToolPlan = true
        let data = try XCTUnwrap(provider.makeRequest(plan).httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        XCTAssertEqual((body["thinking"] as? [String:String])?["type"],"disabled")
        XCTAssertEqual(body["max_tokens"] as? Int,2048)
        XCTAssertEqual((body["response_format"] as? [String:String])?["type"],"json_object")
        let normal = try XCTUnwrap(provider.makeRequest(input()).httpBody)
        XCTAssertEqual((try JSONSerialization.jsonObject(with:normal) as? [String:Any])?["max_tokens"] as? Int,1024)
        XCTAssertNil((try JSONSerialization.jsonObject(with:normal) as? [String:Any])?["response_format"])
    }
    func testProviderSpecificThinkingFieldDoesNotLeakToCustomEndpoints() throws {
        let provider = RitoCustomAPIProvider(endpoint:URL(string:"https://fixture.example/chat/completions")!,model:"fixture")
        let data = try XCTUnwrap(provider.makeRequest(input()).httpBody)
        XCTAssertNil((try JSONSerialization.jsonObject(with:data) as? [String:Any])?["thinking"])
    }
    @MainActor func testKeepAliveAndReasoningStayStatusOnlyThenRealTextAppears() async throws {
        let body = ": keep-alive\n\ndata: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hidden fixture\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"answer\"},\"finish_reason\":\"stop\"}]}\n\n"
        let provider = RitoCustomAPIProvider(endpoint:URL(string:"https://fixture.example/chat/completions")!,model:"fixture",transport:Fixture(body:body))
        var input = input(), phases = 0, text = ""
        input.progress = { _ in phases += 1 }
        let reply = try await provider.stream(to:input) { text += $0 }
        XCTAssertEqual(reply.text,"answer");XCTAssertEqual(text,"answer");XCTAssertGreaterThanOrEqual(phases,4)
    }
    func testReasoningOnlyAndInvalidModelReportSpecificErrors() async throws {
        let body = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"hidden fixture\"},\"finish_reason\":\"length\"}]}\n\n"
        let provider = RitoCustomAPIProvider(endpoint:URL(string:"https://fixture.example/chat/completions")!,model:"fixture",transport:Fixture(body:body))
        do { _ = try await provider.reply(to:input());XCTFail() } catch { XCTAssertEqual(error as? RitoCloudError,.reasoningLimit) }
        let bad = RitoCustomAPIProvider(endpoint:URL(string:"https://fixture.example/chat/completions")!,model:"fixture",transport:Fixture(body:"{\"error\":{\"code\":\"model_not_found\",\"message\":\"private-fixture\"}}",status:400))
        do { _ = try await bad.reply(to:input());XCTFail() } catch {
            XCTAssertEqual(error as? RitoCloudError,.invalidModel)
            XCTAssertFalse(error.localizedDescription.contains("private-fixture"))
        }
    }
    func testPlanParserAcceptsOneFencedObjectButKeepsStrictToolValidation() throws {
        let id = UUID(), attachment = RToolAIAttachment(id:UUID(),name:"a.png",byteCount:1)
        let file = RToolAIAttachment(id:id,name:attachment.name,byteCount:1)
        let json = "{\"message\":\"先确认 {图片}\",\"task\":{\"operation\":\"image_compress\",\"attachmentIDs\":[\"\(id)\"],\"parameters\":{\"maximumKB\":3072},\"following\":null}}"
        let result = try RitoToolCall.decode("以下为方案：\n```json\n" + json + "\n```",attachments:[file])
        XCTAssertEqual(result.1?.operation,.image_compress)
        XCTAssertEqual(result.1?.parameters?["maximumKB"],"3072")
        XCTAssertEqual(try RitoToolCall.decode("```json" + json + "```",attachments:[file]).1?.operation,.image_compress)
        XCTAssertThrowsError(try RitoToolCall.decode(json + "\n" + json,attachments:[file]))
        XCTAssertThrowsError(try RitoToolCall.decode("[" + json + "]",attachments:[file]))
        XCTAssertThrowsError(try RitoToolCall.decode(json.replacingOccurrences(of:"image_compress",with:"run_shell"),attachments:[file]))
    }
    func testMalformedPlannerResponseIsLocalizedAndNeverBecomesExecutable() {
        for text in ["not JSON","{\"message\":\"truncated", "{\"message\":\"test\",\"task\":{\"operation\":\"ocr\",\"attachmentIDs\":[\"not-a-uuid\"]}}"] {
            do { _ = try RitoToolCall.decode(text,attachments:[]);XCTFail() }
            catch { XCTAssertEqual(error as? RitoToolError,.invalidPlan) }
        }
    }
}
