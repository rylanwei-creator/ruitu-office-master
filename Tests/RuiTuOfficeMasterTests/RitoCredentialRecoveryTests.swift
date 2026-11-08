import XCTest
import Foundation
import Security
@testable import RuiTuOfficeMaster

final class RitoCredentialRecoveryTests: XCTestCase, @unchecked Sendable {
    private final class Store: RitoCredentialStore, @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        private var saved: [String: String] = [:]
        private var seen: [String] = []
        var cancelFirst = false
        var delay: TimeInterval = 0
        var count: Int { lock.withLock { reads } }
        var accounts: [String] { lock.withLock { seen } }
        func read(_ account: String) throws -> String? {
            let number = lock.withLock { reads += 1; seen.append(account); return reads }
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if cancelFirst && number == 1 { throw RitoKeychainError(status: errSecUserCanceled) }
            return lock.withLock { saved[account] }
        }
        func save(_ value: String, account: String) throws { lock.withLock { saved[account] = value } }
        func delete(_ account: String) throws { _ = lock.withLock { saved.removeValue(forKey: account) } }
    }
    private actor Transport: RitoStreamingTransport {
        var requests = 0
        func count() -> Int { requests }
        func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, Int) {
            requests += 1
            return (.init { c in
                c.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"连接成功\"}}]}\n\ndata: [DONE]\n\n".utf8))
                c.finish()
            }, 200)
        }
    }
    private func input() -> RToolAIRequest { .init(messages: [], text: "你好", attachments: [], intent: nil) }
    @MainActor private func config(_ store: Store) -> RitoAIConfiguration {
        let name = "rito-key-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let configuration = RitoAIConfiguration(defaults: defaults, keychain: store)
        configuration.mode = .customAPI
        return configuration
    }
    @MainActor func testCreatingAndEditingProviderNeverReadsKeychain() throws {
        let store = Store(), configuration = config(store)
        _ = configuration.makeProvider()
        configuration.modelID = "changed"
        _ = configuration.makeProvider()
        _ = try configuration.customProvider()
        XCTAssertEqual(store.count, 0)
    }
    @MainActor func testCancelledAuthorizationRetriesSameProviderAndStreams() async throws {
        let store = Store(), configuration = config(store), transport = Transport()
        store.cancelFirst = true
        try configuration.saveKey("dummy-fixture-only")
        var provider = try configuration.customProvider(); provider.transport = transport
        do { _ = try await provider.reply(to: input()); XCTFail("Must surface authorization cancellation") }
        catch { XCTAssertEqual(error as? RitoKeychainError, .init(status: errSecUserCanceled)) }
        let before = await transport.count(); XCTAssertEqual(before, 0)
        var text = ""
        let result = try await provider.stream(to: input()) { text += $0 }
        XCTAssertEqual(result.text, "连接成功"); XCTAssertEqual(text, result.text)
        XCTAssertEqual(store.count, 2)
        let after = await transport.count(); XCTAssertEqual(after, 1)
    }
    @MainActor func testOriginChangeCannotForwardPreviousCredential() async throws {
        let store = Store(), configuration = config(store)
        try configuration.saveKey("dummy-fixture-only")
        let old = try configuration.customProvider()
        configuration.endpoint = "https://another.example/chat/completions"
        let next = try configuration.customProvider()
        XCTAssertNotEqual(old.account, next.account)
        do { _ = try await next.resolve(); XCTFail("Missing key at new origin") }
        catch { XCTAssertEqual(error as? RitoCloudError, .notConfigured) }
        _ = try await old.resolve()
        XCTAssertEqual(store.accounts, [next.account, old.account])
    }
    @MainActor func testCancelledRequestNeverSendsAfterLateAuthorization() async throws {
        let store = Store(), configuration = config(store), transport = Transport()
        store.delay = 0.15
        try configuration.saveKey("dummy-fixture-only")
        var provider = try configuration.customProvider(); provider.transport = transport
        let snapshot = provider, request = input()
        let work = Task { try await snapshot.reply(to: request) }
        for _ in 0..<100 where store.count == 0 { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(store.count, 1)
        work.cancel()
        do { _ = try await work.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.count(); XCTAssertEqual(count, 0)
    }
    private actor OnceFailing: AIProvider {
        var attempts = 0
        var files: [RToolAIAttachment] = []
        nonisolated var source: RitoReplySource { .custom }
        nonisolated var capabilities: AIProviderCapabilities { .init() }
        func reply(to request: RToolAIRequest) async throws -> RToolAIReply {
            attempts += 1; files = request.attachments
            if attempts == 1 { throw RitoKeychainError(status: errSecUserCanceled) }
            return .init(text: "恢复成功", task: nil)
        }
        func receivedFiles() -> [RToolAIAttachment] { files }
    }
    @MainActor private func wait(_ vm: RToolAIViewModel) async throws {
        for _ in 0..<500 where vm.isBusy { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(vm.isBusy)
    }
    @MainActor func testReplyRetryPreservesAttachmentsAndDoesNotDuplicateUser() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("test".utf8).write(to: root); defer { try? FileManager.default.removeItem(at: root) }
        let service = OnceFailing(), vm = RToolAIViewModel(responder: service)
        vm.addAttachments([root]); vm.draft = "提取文字"; vm.send()
        try await wait(vm)
        XCTAssertTrue(vm.canRetryReply); XCTAssertEqual(vm.messages.count, 1)
        var first = vm.messages[0]
        XCTAssertNotNil(first.replyIssue); first.replyIssue = nil
        vm.retryReply(); try await wait(vm)
        XCTAssertFalse(vm.canRetryReply); XCTAssertNil(vm.notice)
        XCTAssertEqual(vm.messages.count, 2); XCTAssertEqual(vm.messages[0], first)
        XCTAssertEqual(vm.messages.last?.text, "恢复成功")
        let files = await service.receivedFiles(); XCTAssertEqual(files, first.attachments)
    }
    @MainActor func testNewConversationClearsFailedRequest() async throws {
        let vm = RToolAIViewModel(responder: OnceFailing())
        vm.draft = "你好"; vm.send(); try await wait(vm)
        XCTAssertTrue(vm.canRetryReply)
        vm.newConversation(); vm.retryReply()
        XCTAssertFalse(vm.canRetryReply); XCTAssertTrue(vm.messages.isEmpty); XCTAssertFalse(vm.isBusy)
    }
    func testKeychainErrorsExplainAuthorizationWithoutSecrets() {
        let error = RitoKeychainError(status: errSecUserCanceled)
        XCTAssertEqual(errSecUserCanceled, -128)
        XCTAssertTrue(error.localizedDescription.contains("尚未发送"))
        XCTAssertTrue(error.localizedDescription.contains("重试"))
        XCTAssertFalse(error.localizedDescription.contains("dummy-fixture-only"))
        XCTAssertNotEqual(error.localizedDescription, RitoKeychainError(status: errSecAuthFailed).localizedDescription)
    }
}
