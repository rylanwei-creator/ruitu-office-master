import XCTest
import Foundation
@testable import RuiTuOfficeMaster

final class RitoAIHistoryTests: XCTestCase, @unchecked Sendable {
    private let fast = RToolAIMockService(replyDelay: .zero, stepDelay: .zero)
    @MainActor private func settle(_ model: RToolAIViewModel) async {
        for _ in 0..<10000 { if !model.isBusy { return }; await Task.yield() }
        XCTFail("Reply did not finish")
    }
    @MainActor func testNewChatPreservesOldHistoryAndReopeningKeepsSources() async throws {
        let model = RToolAIViewModel(responder: fast, simulator: fast)
        model.choose(.extractText); model.send(); await settle(model)
        let first = model.conversationID, messages = model.messages
        model.newConversation(); XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.conversations.count, 1)
        model.draft = "第二个对话"; model.send(); await settle(model)
        let second = model.conversationID
        model.openConversation(first)
        XCTAssertEqual(model.conversationID, first); XCTAssertEqual(model.messages, messages)
        XCTAssertEqual(model.conversations.count, 2)
        let taskID = try XCTUnwrap(model.messages.last?.task?.id)
        model.confirm(taskID); await settle(model)
        model.openConversation(second)
        XCTAssertEqual(model.messages.first?.text, "第二个对话")
        model.openConversation(first)
        XCTAssertEqual(model.messages.last?.task?.state, .completed)
    }
    @MainActor func testHistoryLimitAndDeleteOnlySpecifiedChat() async {
        let model = RToolAIViewModel(responder: fast, simulator: fast)
        for i in 0..<32 { model.newConversation(); model.draft = "chat \(i)"; model.send(); await settle(model) }
        XCTAssertEqual(model.conversations.count, 30)
        XCTAssertFalse(model.conversations.contains { $0.title == "chat 0" })
        let current = model.conversationID, old = model.conversations[4].id
        model.deleteConversation(old)
        XCTAssertEqual(model.conversations.count, 29); XCTAssertEqual(model.conversationID, current)
        XCTAssertFalse(model.messages.isEmpty)
        model.deleteConversation(current)
        XCTAssertTrue(model.messages.isEmpty); XCTAssertEqual(model.conversations.count, 28)
        XCTAssertNotEqual(model.conversationID, current)
    }
    @MainActor func testHistoryRoundTripRecoversTaskIdentityAndCancelsInterruptedExecution() async throws {
        let suite = "rito-history-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RitoAIHistoryStore(defaults: defaults)
        let slow = RToolAIMockService(replyDelay: .zero, stepDelay: .seconds(30))
        let model = RToolAIViewModel(responder: fast, simulator: slow, historyStore: store)
        model.choose(.organize); model.send(); await settle(model)
        let id = model.conversationID, taskID = try XCTUnwrap(model.messages.last?.task?.id)
        model.confirm(taskID)
        let restored = RToolAIViewModel(responder: fast, simulator: fast, historyStore: store)
        restored.openConversation(id)
        XCTAssertEqual(restored.messages.last?.task?.id, taskID)
        XCTAssertEqual(restored.messages.last?.task?.state, .cancelled)
        XCTAssertFalse(restored.isBusy)
        model.stop()
        restored.deleteConversation(id)
        XCTAssertTrue(store.load().isEmpty)
    }
    @MainActor func testPDFShortcutCreatesOnlyConfirmedMockResults() async throws {
        let model = RToolAIViewModel(responder: fast, simulator: fast)
        model.choose(.pdfDocument); model.send(); await settle(model)
        let plan = try XCTUnwrap(model.messages.last?.task)
        XCTAssertEqual(plan.intent, .pdfDocument)
        XCTAssertEqual(plan.state, .awaitingConfirmation)
        XCTAssertTrue(plan.results.isEmpty)
        model.confirm(plan.id); await settle(model)
        XCTAssertEqual(model.messages.last?.task?.state, .completed)
        XCTAssertTrue(model.messages.last?.task?.results.first?.detail.contains("未读取或生成 PDF") == true)
    }

    private actor Gate: RToolAIResponding {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func reply(to request: RToolAIRequest) async throws -> RToolAIReply {
            started = true; await withCheckedContinuation { continuation = $0 }
            return .init(text: "late", task: nil)
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    @MainActor func testHistorySwitchCannotReceiveOldLateReply() async {
        let gate = Gate()
        let model = RToolAIViewModel(responder: gate, simulator: fast)
        model.draft = "first"; model.send()
        while !(await gate.started) { await Task.yield() }
        let first = model.conversationID
        model.newConversation(); model.openConversation(first)
        await gate.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(model.messages.count, 1); XCTAssertEqual(model.messages.first?.text, "first")
        XCTAssertFalse(model.isBusy)
    }
    @MainActor private func seededHistory(_ store: RitoAIHistoryStore? = nil) -> [RitoAIConversation] {
        let plan = RToolAITaskPlan(id: UUID(), intent: .extractText, sourceNames: ["seed.png"])
        let old = RitoAIConversation(id: UUID(), messages: [
            .init(id: UUID(), role: .user, text: "旧对话"),
            .init(id: UUID(), role: .assistant, text: "已有方案", task: plan, source: .mock)
        ], updatedAt: Date(timeIntervalSince1970: 10))
        let middle = RitoAIConversation(id: UUID(), messages: [.init(id: UUID(), role: .user, text: "中间对话")],
            updatedAt: Date(timeIntervalSince1970: 20))
        let newest = RitoAIConversation(id: UUID(), messages: [.init(id: UUID(), role: .user, text: "新对话")],
            updatedAt: Date(timeIntervalSince1970: 30))
        let records = [newest, middle, old]
        store?.save(records)
        return records
    }
    @MainActor private func historyStore() throws -> (RitoAIHistoryStore, String) {
        let suite = "rito-order-test-" + UUID().uuidString
        return (RitoAIHistoryStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))), suite)
    }
    @MainActor func testBrowsingAndSwitchingPreserveOrderTimeAndPersistedHistory() throws {
        let (store, suite) = try historyStore()
        defer { store.defaults.removePersistentDomain(forName: suite) }
        let before = seededHistory(store)
        let vm = RToolAIViewModel(responder: fast, historyStore: store)
        for _ in 0..<3 {
            vm.openConversation(before[2].id)
            vm.openConversation(before[0].id)
            vm.openConversation(before[1].id)
            vm.stop()
            vm.newConversation()
        }
        XCTAssertEqual(vm.conversations, before)
        XCTAssertEqual(store.load(), before)
        XCTAssertEqual(RToolAIViewModel(responder: fast, historyStore: store).conversations, before)
    }
    @MainActor func testSendingInOldConversationMovesOnlyChangedRecordToTop() async throws {
        let (store, suite) = try historyStore()
        defer { store.defaults.removePersistentDomain(forName: suite) }
        let before = seededHistory(store)
        let vm = RToolAIViewModel(responder: fast, historyStore: store)
        vm.openConversation(before[2].id)
        vm.draft = "继续聊天"; vm.send(); await settle(vm)
        XCTAssertEqual(vm.conversations.map(\.id), [before[2].id, before[0].id, before[1].id])
        XCTAssertGreaterThan(vm.conversations[0].updatedAt, before[2].updatedAt)
        XCTAssertEqual(Array(vm.conversations.dropFirst()), Array(before.prefix(2)))
        let modified = vm.conversations
        vm.openConversation(before[1].id); vm.openConversation(before[2].id); vm.newConversation()
        XCTAssertEqual(vm.conversations, modified); XCTAssertEqual(store.load(), modified)
    }
    @MainActor func testRenameMovesTargetToTopAndSameNameIsNoOp() throws {
        let (store, suite) = try historyStore()
        defer { store.defaults.removePersistentDomain(forName: suite) }
        let before = seededHistory(store)
        let vm = RToolAIViewModel(responder: fast, historyStore: store)
        vm.openConversation(before[1].id)
        vm.renameConversation(before[2].id, title: "重命名后的旧对话")
        XCTAssertEqual(vm.conversations.map(\.id), [before[2].id, before[0].id, before[1].id])
        XCTAssertEqual(vm.conversations[0].messages, before[2].messages)
        XCTAssertGreaterThan(vm.conversations[0].updatedAt, before[2].updatedAt)
        let after = vm.conversations
        vm.renameConversation(before[2].id, title: "  重命名后的旧对话  ")
        vm.renameConversation(before[0].id, title: before[0].title)
        vm.renameConversation(before[1].id, title: "  ")
        XCTAssertEqual(vm.conversations, after); XCTAssertEqual(store.load(), after)
        XCTAssertEqual(vm.conversationID, before[1].id)
    }
    @MainActor func testCurrentConversationRenameSurvivesNavigationWithoutRetiming() throws {
        let (store, suite) = try historyStore()
        defer { store.defaults.removePersistentDomain(forName: suite) }
        let before = seededHistory(store)
        let vm = RToolAIViewModel(responder: fast, historyStore: store)
        vm.openConversation(before[2].id)
        vm.renameConversation(before[2].id, title: "当前会话新名字")
        let after = vm.conversations
        vm.openConversation(before[1].id); vm.openConversation(before[2].id)
        XCTAssertEqual(vm.conversations, after)
        XCTAssertEqual(vm.conversations.first?.customTitle, "当前会话新名字")
    }
    @MainActor func testTaskMutationUpdatesOrderButViewingTaskDoesNot() throws {
        let (store, suite) = try historyStore()
        defer { store.defaults.removePersistentDomain(forName: suite) }
        let before = seededHistory(store)
        let vm = RToolAIViewModel(responder: fast, historyStore: store)
        vm.openConversation(before[2].id)
        XCTAssertEqual(vm.conversations, before)
        vm.dismiss(try XCTUnwrap(vm.messages.last?.task?.id))
        XCTAssertEqual(vm.conversations[0].id, before[2].id)
        XCTAssertGreaterThan(vm.conversations[0].updatedAt, before[2].updatedAt)
        XCTAssertEqual(vm.conversations[0].messages.last?.task?.state, .cancelled)
        XCTAssertEqual(Array(vm.conversations.dropFirst()), Array(before.prefix(2)))
    }
    @MainActor func testCancellingBeforeReplyDoesNotRetimestampUnchangedSentMessage() async {
        let gate = Gate()
        let vm = RToolAIViewModel(responder: gate)
        vm.draft = "等待回复"; vm.send()
        while !(await gate.started) { await Task.yield() }
        let afterSend = vm.conversations
        vm.newConversation()
        XCTAssertEqual(vm.conversations, afterSend)
        await gate.release()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(vm.conversations, afterSend)
    }

}
