import XCTest
import Foundation
@testable import RuiTuOfficeMaster

final class RitoPlanRecoveryTests: XCTestCase, @unchecked Sendable {
    private actor Planner: AIProvider {
        nonisolated var source: RitoReplySource { .custom }
        nonisolated var capabilities: AIProviderCapabilities { .init() }
        let replies: [String]
        let failure: RitoCloudError?
        let pause: Bool
        var inputs: [RToolAIRequest] = []
        init(_ replies: [String], failure: RitoCloudError? = nil, pause: Bool = false) {
            self.replies = replies; self.failure = failure; self.pause = pause
        }
        func snapshot() -> [RToolAIRequest] { inputs }
        func reply(to request: RToolAIRequest) async throws -> RToolAIReply {
            try await stream(to: request) { _ in }
        }
        func stream(to request: RToolAIRequest, delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
            inputs.append(request)
            if let failure { throw failure }
            if pause { try await Task.sleep(for: .seconds(30)) }
            try Task.checkCancellation()
            let value = replies[min(inputs.count - 1, replies.count - 1)]
            await delta(value)
            return .init(text: value, task: nil)
        }
    }
    private let file = RToolAIAttachment(id: UUID(), name: "PRIVATE_photo.jpg", byteCount: 7)
    private func request() -> RToolAIRequest {
        .init(messages: [.init(id: UUID(), role: .assistant, text: "old PDF plan", source: .custom)],
            text: "换成红底", attachments: [file], intent: nil)
    }
    private func valid(_ id: UUID) -> String {
        "{\"message\":\"将使用证件照工具换红底，先预览\",\"task\":{\"operation\":\"id_photo\",\"attachmentIDs\":[\"\(id)\"],\"parameters\":{\"background\":\"red\"}}}"
    }
    @MainActor func testMalformedPlanAutomaticallyRepairsBeforeReturningOneSafeTask() async throws {
        let planner = Planner(["invalid first output", valid(file.id)])
        var input = request(), phases: [RitoConnectionPhase] = [], visible = ""
        input.progress = { phases.append($0) }
        let reply = try await RitoOfficeProvider(underlying: planner).stream(to: input) { visible += $0 }
        XCTAssertEqual(reply.task?.liveCall?.operation, .id_photo)
        XCTAssertEqual(reply.task?.liveCall?.parameters?["background"], "red")
        XCTAssertFalse(reply.applicationNotice)
        XCTAssertFalse(visible.contains("invalid first output"))
        XCTAssertFalse(visible.contains("attachmentIDs"))
        XCTAssertEqual(phases.filter { if case .repairingPlan = $0 { true } else { false } }.count, 1)
        let inputs = await planner.snapshot()
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs[1].messages.isEmpty)
        XCTAssertEqual(inputs[1].text, input.text)
        XCTAssertTrue(inputs.allSatisfy { $0.attachments.isEmpty && $0.expectsToolPlan })
        XCTAssertTrue(inputs[1].toolInstructions?.contains(file.id.uuidString) == true)
        XCTAssertFalse(inputs[1].toolInstructions?.contains(file.name) == true)
        XCTAssertFalse(inputs[1].toolInstructions?.contains("invalid first output") == true)
    }
    func testValidFirstPlanNeverSendsSecondRequest() async throws {
        let planner = Planner([valid(file.id)])
        let reply = try await RitoOfficeProvider(underlying: planner).reply(to: request())
        XCTAssertNotNil(reply.task)
        let count = await planner.snapshot().count
        XCTAssertEqual(count, 1)
    }
    func testInvalidParametersAlsoRepairWithoutRelaxingValidation() async throws {
        let wrong = valid(file.id).replacingOccurrences(of: "\"red\"", with: "\"红底\"")
        XCTAssertThrowsError(try RitoToolCall.decode(wrong, attachments: [file]))
        let planner = Planner([wrong, valid(file.id)])
        let reply = try await RitoOfficeProvider(underlying: planner).reply(to: request())
        XCTAssertEqual(reply.task?.liveCall?.parameters?["background"], "red")
        let count = await planner.snapshot().count
        XCTAssertEqual(count, 2)
    }
    func testTwoRejectedPlansProduceLabelledApplicationNoticeAndNoExecutableTask() async throws {
        let unsafe = valid(file.id).replacingOccurrences(of: "id_photo", with: "run_shell")
        let planner = Planner([unsafe])
        let reply = try await RitoOfficeProvider(underlying: planner).reply(to: request())
        XCTAssertTrue(reply.applicationNotice)
        XCTAssertNil(reply.task)
        XCTAssertTrue(reply.text.hasPrefix("应用提示："))
        XCTAssertTrue(reply.text.contains("已连接 AI 服务"))
        XCTAssertFalse(reply.text.contains("run_shell"))
        let count = await planner.snapshot().count
        XCTAssertEqual(count, 2)
    }
    func testClarificationWithNullTaskIsARealReplyAndDoesNotRetry() async throws {
        let planner = Planner(["{\"message\":\"你希望换成什么底色？\",\"task\":null}"])
        let reply = try await RitoOfficeProvider(underlying: planner).reply(to: request())
        XCTAssertEqual(reply.text, "你希望换成什么底色？")
        XCTAssertNil(reply.task); XCTAssertFalse(reply.applicationNotice)
        let count = await planner.snapshot().count
        XCTAssertEqual(count, 1)
    }
    func testOrdinaryTextChatKeepsStreamingWithoutPlannerEnvelope() async throws {
        let planner = Planner(["你好，我是 Rito。"])
        let input = RToolAIRequest(messages: [], text: "你好", attachments: [], intent: nil)
        let reply = try await RitoOfficeProvider(underlying: planner).reply(to: input)
        XCTAssertEqual(reply.text, "你好，我是 Rito。")
        let inputs = await planner.snapshot()
        XCTAssertEqual(inputs.count, 1); XCTAssertFalse(inputs[0].expectsToolPlan)
    }
    func testAuthorizationErrorsAreNotReplayedOrMasqueradedAsPlanFailures() async throws {
        let planner = Planner([], failure: .internalAccess)
        do { _ = try await RitoOfficeProvider(underlying: planner).reply(to: request()); XCTFail() }
        catch { XCTAssertEqual(error as? RitoCloudError, .internalAccess) }
        let count = await planner.snapshot().count
        XCTAssertEqual(count, 1)
    }
    func testPlannerDeadlineRemainsBounded() async throws {
        let planner = Planner(["unused"], pause: true)
        do { _ = try await RitoOfficeProvider(underlying: planner, planningTimeout: 0.04).reply(to: request()); XCTFail() }
        catch { XCTAssertEqual(error as? RitoCloudError, .timeout) }
        let count = await planner.snapshot().count
        XCTAssertEqual(count, 1)
    }
    func testCancellationDoesNotStartRepairOrPublishFallbackNotice() async throws {
        let planner = Planner(["unused"], pause: true), input = request()
        let task = Task { try await RitoOfficeProvider(underlying: planner).reply(to: input) }
        for _ in 0..<100 { if await planner.snapshot().count > 0 { break }; try await Task.sleep(for: .milliseconds(2)) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let count = await planner.snapshot().count
        XCTAssertEqual(count, 1)
    }
    @MainActor func testFailedPlanningKeepsSingleUserAndOriginalFileForRetry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([1]).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let planner = Planner(["invalid"])
        let vm = RToolAIViewModel(responder: RitoOfficeProvider(underlying: planner))
        vm.addAttachments([url]); vm.draft = "换红底"; vm.send()
        for _ in 0..<200 where vm.isBusy { try await Task.sleep(for: .milliseconds(3)) }
        XCTAssertFalse(vm.isBusy); XCTAssertTrue(vm.canRetryReply)
        XCTAssertEqual(vm.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(vm.messages.last?.applicationNotice, true)
        XCTAssertNil(vm.messages.last?.task)
        XCTAssertEqual(vm.messages.first?.attachments.count, 1)
        vm.retryReply()
        for _ in 0..<200 where vm.isBusy { try await Task.sleep(for: .milliseconds(3)) }
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages.filter { $0.role == .user }.count, 1)
        XCTAssertEqual(try Data(contentsOf: url), Data([1]))
        let count = await planner.snapshot().count
        XCTAssertEqual(count, 4)
    }
    func testPlannerInstructionsStayWithinContextBudgetForSupportedAttachmentKinds() async throws {
        for name in ["sample.jpg", "sample.pdf", "sample.mp4", "sample.docx", "folder"] {
            let f = RToolAIAttachment(id: UUID(), name: name, byteCount: 1, isDirectory: name == "folder")
            let planner = Planner(["invalid", "{\"message\":\"请补充参数\",\"task\":null}"])
            let files = [f] + (1..<8).map { _ in RToolAIAttachment(id: UUID(), name: name, byteCount: 1, isDirectory: name == "folder") }
            _ = try await RitoOfficeProvider(underlying: planner).reply(to: .init(messages: [], text: "test", attachments: files, intent: nil))
            let inputs = await planner.snapshot()
            XCTAssertEqual(inputs.count, 2)
            for input in inputs {
                XCTAssertLessThanOrEqual(input.toolInstructions?.utf8.count ?? .max, 12000, name)
                XCTAssertNoThrow(try RitoConversationContext.messages(input, byteLimit: 6000))
            }
        }
    }
    func testLocalApplicationNoticesAreExcludedFromModelContextAndHistoryRoundTrips() throws {
        let message = RToolAIMessage(id: UUID(), role: .assistant, text: "local plan failure", source: .custom, applicationNotice: true)
        let context = try RitoConversationContext.messages(.init(messages: [message], text: "你好", attachments: [], intent: nil))
        XCTAssertFalse(context.contains { $0["content"] == message.text })
        let decoded = try JSONDecoder().decode(RToolAIMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.applicationNotice, true)
        XCTAssertThrowsError(try RitoToolCall.decode("{\"message\":\"   \",\"task\":null}", attachments: []))
    }
    private final class CountedCredentials: RitoCredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func count() -> Int { lock.withLock { reads } }
        func read(_ account: String) throws -> String? {
            lock.withLock { reads += 1 }
            return "fixture-only-not-a-key"
        }
        func save(_ value: String, account: String) throws {}
        func delete(_ account: String) throws {}
    }
    private actor ResponseTransport: RitoStreamingTransport {
        let contents: [String]
        var calls = 0
        init(_ contents: [String]) { self.contents = contents }
        func count() -> Int { calls }
        func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, Int) {
            let text = contents[min(calls, contents.count - 1)]; calls += 1
            let payload = try JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": text], "finish_reason": "stop"]]])
            let event = Data("data: ".utf8) + payload + Data("\n\n".utf8)
            return (.init { c in c.yield(event); c.finish() }, 200)
        }
    }
    func testAutomaticPlanRepairReadsCredentialsOnlyOncePerUserSend() async throws {
        let credentials = CountedCredentials()
        let transport = ResponseTransport(["invalid", valid(file.id)])
        let cloud = RitoCredentialAPIProvider(endpoint: URL(string: "https://fixture.example/chat/completions")!,
            model: "fixture", account: "fixture", credentials: credentials, transport: transport)
        let reply = try await RitoOfficeProvider(underlying: cloud).reply(to: request())
        XCTAssertEqual(reply.task?.liveCall?.operation, .id_photo)
        XCTAssertEqual(credentials.count(), 1)
        let count = await transport.count()
        XCTAssertEqual(count, 2)
    }
}
