import XCTest
import Foundation
@testable import RuiTuOfficeMaster

final class RToolAITests: XCTestCase, @unchecked Sendable {
    private let fast = RToolAIMockService(replyDelay: .zero, stepDelay: .zero)

    @MainActor private func settle(_ model: RToolAIViewModel) async {
        for _ in 0..<10000 {
            if !model.isBusy { return }
            await Task.yield()
        }
        XCTFail("Simulation did not finish")
    }

    @MainActor func testEmptyMessageAndDuplicateSendAreRejected() async {
        let model = RToolAIViewModel(responder: fast, simulator: fast)
        model.draft = " \n "; model.send(); XCTAssertTrue(model.messages.isEmpty)
        model.draft = "你好"; model.send(); model.send()
        XCTAssertEqual(model.messages.count, 1)
        await settle(model)
        XCTAssertEqual(model.messages.count, 2)
        XCTAssertEqual(model.messages.last?.role, .assistant)
        XCTAssertTrue(model.messages.last?.text.contains("模拟回复") == true)
    }

    @MainActor func testTaskDoesNotRunUntilExplicitConfirmationAndCannotRunTwice() async throws {
        let model = RToolAIViewModel(responder: fast, simulator: fast)
        model.choose(.organize); model.send(); await settle(model)
        let plan = try XCTUnwrap(model.messages.last?.task)
        XCTAssertEqual(plan.state, .awaitingConfirmation)
        XCTAssertTrue(plan.results.isEmpty)
        model.confirm(plan.id); model.confirm(plan.id)
        await settle(model)
        XCTAssertEqual(model.messages.last?.task?.state, .completed)
        XCTAssertEqual(model.messages.last?.task?.progress, 1)
        XCTAssertEqual(model.messages.last?.task?.results.count, 1)
        model.confirm(plan.id)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor func testCancelledProposalCannotExecute() async throws {
        let model = RToolAIViewModel(responder: fast, simulator: fast)
        model.choose(.extractText); model.send(); await settle(model)
        let id = try XCTUnwrap(model.messages.last?.task?.id)
        model.dismiss(id); model.confirm(id)
        XCTAssertEqual(model.messages.last?.task?.state, .cancelled)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor func testAttachmentsKeepSeparateSourcesAndNeverChangeFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("第一张.png"), b = directory.appendingPathComponent("第二张.jpg")
        let dataA = Data("not an image: metadata only".utf8), dataB = Data("keep me".utf8)
        try dataA.write(to: a); try dataB.write(to: b)
        let model = RToolAIViewModel(responder: fast, simulator: fast)
        model.addAttachments([a, b, a]); XCTAssertEqual(model.attachments.count, 2)
        model.choose(.extractText); model.send(); await settle(model)
        XCTAssertEqual(model.messages.first?.attachments.map(\.name), [a.lastPathComponent, b.lastPathComponent])
        XCTAssertTrue(model.attachments.isEmpty)
        let id = try XCTUnwrap(model.messages.last?.task?.id)
        model.confirm(id); await settle(model)
        XCTAssertEqual(model.messages.last?.task?.results.map(\.sourceName), [a.lastPathComponent, b.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: a), dataA); XCTAssertEqual(try Data(contentsOf: b), dataB)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    @MainActor func testAttachmentLimitAndRemovalPreserveDeduplication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (0..<10).map { index -> URL in
            let url = directory.appendingPathComponent("\(index).txt"); try Data([1]).write(to: url); return url
        }
        let model = RToolAIViewModel()
        model.addAttachments(files + [directory]); XCTAssertEqual(model.attachments.count, 8)
        let first = try XCTUnwrap(model.attachments.first?.id)
        model.removeAttachment(first)
        model.addAttachments([files[1]])
        XCTAssertEqual(model.attachments.count, 7, "Remaining attachment must remain deduplicated")
        model.addAttachments([files[0]])
        XCTAssertEqual(model.attachments.count, 8, "Removed attachment can be added again")
    }

    private actor GateResponder: RToolAIResponding {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func reply(to request: RToolAIRequest) async throws -> RToolAIReply {
            started = true
            await withCheckedContinuation { continuation = $0 }
            return .init(text: "late response", task: nil)
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor func testResetRejectsLateReplyFromCancelledConversation() async {
        let gate = GateResponder()
        let model = RToolAIViewModel(responder: gate, simulator: fast)
        model.draft = "old conversation"; model.send()
        while !(await gate.started) { await Task.yield() }
        model.newConversation()
        await gate.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(model.messages.isEmpty); XCTAssertFalse(model.isBusy); XCTAssertTrue(model.draft.isEmpty)
    }

    @MainActor func testStopExecutionKeepsProposalCancelledAndNoResults() async throws {
        let slow = RToolAIMockService(replyDelay: .zero, stepDelay: .seconds(30))
        let model = RToolAIViewModel(responder: fast, simulator: slow)
        model.choose(.summarize); model.send(); await settle(model)
        let id = try XCTUnwrap(model.messages.last?.task?.id)
        model.confirm(id); model.stop()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(model.messages.last?.task?.state, .cancelled)
        XCTAssertTrue(model.messages.last?.task?.results.isEmpty == true)
    }

    private struct FailingService: RToolAIResponding, RToolAITaskSimulating {
        func reply(to request: RToolAIRequest) async throws -> RToolAIReply { throw URLError(.notConnectedToInternet) }
        func simulate(_ plan: RToolAITaskPlan, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [RToolAIResult] { throw URLError(.unknown) }
    }

    @MainActor func testReplyFailureReleasesBusyStateAndRetainsUserMessage() async {
        let model = RToolAIViewModel(responder: FailingService(), simulator: fast)
        model.draft = "test"; model.send(); await settle(model)
        XCTAssertEqual(model.messages.count, 1)
        XCTAssertNotNil(model.notice)
        model.draft = "retry"; XCTAssertTrue(model.canSend)
    }

    @MainActor func testExecutionFailureIsVisibleAndLeavesNoResult() async throws {
        let model = RToolAIViewModel(responder: fast, simulator: FailingService())
        model.choose(.plan); model.send(); await settle(model)
        let id = try XCTUnwrap(model.messages.last?.task?.id)
        model.confirm(id); await settle(model)
        XCTAssertEqual(model.messages.last?.task?.state, .failed)
        XCTAssertNotNil(model.messages.last?.task?.error)
        XCTAssertTrue(model.messages.last?.task?.results.isEmpty == true)
    }
}
