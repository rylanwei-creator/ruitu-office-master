import XCTest
import Foundation
@testable import RuiTuOfficeMaster

final class RitoReplyDeadlineTests: XCTestCase, @unchecked Sendable {
    private func request() -> RToolAIRequest { .init(messages:[],text:"test",attachments:[],intent:nil) }
    private struct SilentTransport: RitoStreamingTransport {
        let headers: Bool
        func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data,Error>,Int) {
            if !headers {
                // Deliberately non-cooperative external system call, like authorization.
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline:.now() + 0.2) { continuation.resume() }
                }
            }
            return (.init { _ in },200)
        }
    }
    private struct FinishTransport: RitoStreamingTransport {
        let reason: String
        func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data,Error>,Int) {
            (.init { c in
                c.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":\"\(reason)\"}]}\n\n".utf8))
                // A compatible service may leave HTTP open after finish_reason.
            },200)
        }
    }
    private func provider(_ transport: any RitoStreamingTransport) -> RitoCustomAPIProvider {
        .init(endpoint:URL(string:"https://fixture.example/chat/completions")!,authorization:"fixture-only",model:"fixture",transport:transport,responseTimeout:0.04)
    }
    func testHeadersNeverArriveStillReturnsAtHardDeadline() async throws {
        let start = Date()
        do { _ = try await provider(SilentTransport(headers:false)).reply(to:request());XCTFail() }
        catch { XCTAssertEqual(error as? RitoCloudError,.timeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start),0.15)
    }
    func testHeadersWithoutTextCannotSpinForever() async throws {
        do { _ = try await provider(SilentTransport(headers:true)).reply(to:request());XCTFail() }
        catch { XCTAssertEqual(error as? RitoCloudError,.timeout) }
    }
    func testFinishReasonStopsStreamWithoutWaitingForDoneOrEOF() async throws {
        let reply = try await provider(FinishTransport(reason:"stop")).reply(to:request())
        XCTAssertEqual(reply.text,"hello")
        do { _ = try await provider(FinishTransport(reason:"length")).reply(to:request());XCTFail() }
        catch { XCTAssertEqual(error as? RitoCloudError,.incomplete) }
    }
    private final class SlowStore: RitoCredentialStore, @unchecked Sendable {
        func read(_ account: String) throws -> String? { Thread.sleep(forTimeInterval:0.2);return "fixture-only" }
        func save(_ value: String,account:String) throws {}
        func delete(_ account: String) throws {}
    }
    private actor CounterTransport: RitoStreamingTransport {
        var count = 0
        func requests() -> Int { count }
        func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data,Error>,Int) { count += 1;return (.init { $0.finish() },200) }
    }
    @MainActor func testAuthorizationTimeoutDoesNotSendAfterLateUnlock() async throws {
        let transport = CounterTransport()
        let provider = RitoCredentialAPIProvider(endpoint:URL(string:"https://fixture.example/chat/completions")!,model:"fixture",account:"fixture",credentials:SlowStore(),transport:transport,credentialTimeout:0.03)
        var phases: [RitoConnectionPhase] = []
        var input = request();input.progress = { phases.append($0) }
        let start = Date()
        do { _ = try await provider.reply(to:input);XCTFail() }
        catch { XCTAssertEqual(error as? RitoCloudError,.credentialTimeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start),0.15)
        XCTAssertEqual(phases.count,1)
        try await Task.sleep(for:.milliseconds(240))
        let count = await transport.requests();XCTAssertEqual(count,0)
    }
    func testCancellationReturnsEvenWhenExternalWorkIgnoresIt() async throws {
        let task = Task {
            try await RitoAsyncDeadline.run(seconds:10) {
                await withCheckedContinuation { continuation in DispatchQueue.global().asyncAfter(deadline:.now()+0.2) { continuation.resume(returning:"late") } }
            }
        }
        try await Task.sleep(for:.milliseconds(5));task.cancel()
        do { _ = try await task.value;XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }
    private struct InvalidPlanner: AIProvider {
        var source: RitoReplySource { .custom }
        var capabilities: AIProviderCapabilities { .init() }
        func reply(to request:RToolAIRequest) async throws -> RToolAIReply { throw RitoToolError.invalidPlan }
        func stream(to request:RToolAIRequest,delta:@escaping @MainActor @Sendable(String)->Void) async throws -> RToolAIReply {
            await delta("正在生成受控方案…");throw RitoToolError.invalidPlan
        }
    }
    @MainActor func testFailedPlanAnnouncementIsRemovedAndCanRetryWithOriginalAttachment() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("fixture".utf8).write(to:url);defer { try? FileManager.default.removeItem(at:url) }
        let vm = RToolAIViewModel(responder:InvalidPlanner())
        vm.addAttachments([url]);vm.draft = "test";vm.send()
        for _ in 0..<100 where vm.isBusy { try await Task.sleep(for:.milliseconds(2)) }
        XCTAssertFalse(vm.isBusy);XCTAssertTrue(vm.canRetryReply)
        XCTAssertEqual(vm.messages.count,1);XCTAssertEqual(vm.messages[0].attachments.count,1)
        XCTAssertNotNil(vm.notice)
    }
}
