import XCTest
import Foundation
import CryptoKit
import PDFKit
@testable import RuiTuOfficeMaster

final class RitoDualModeTests: XCTestCase, @unchecked Sendable {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rito-dual-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    private func input(_ text: String, files: [RToolAIAttachment] = []) -> RToolAIRequest {
        .init(messages: [], text: text, attachments: files, intent: nil)
    }
    private struct Fixture: RitoStreamingTransport {
        let bytes: Data
        var status = 200
        func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, Int) {
            (.init { c in for byte in bytes { c.yield(Data([byte])) }; c.finish() }, status)
        }
    }
    private func provider(_ data: String, status: Int = 200) -> RitoCustomAPIProvider {
        .init(endpoint: URL(string: "https://api.example.com/chat/completions")!, authorization: "test-key", model: "model",
              transport: Fixture(bytes: Data(data.utf8), status: status))
    }
    func testSSEHandlesSingleByteChineseAndThinkingFrames() async throws {
        let stream = ["<thi", "nk>hidden</th", "ink>\n\n你好", " world"].map { value in
            let data = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": ["content": value]]]])
            return "data: " + String(decoding: data, as: UTF8.self) + "\r\n\r\n"
        }.joined() + "data: [DONE]\r\n\r\n"
        let answer = try await provider(stream).reply(to: input("你好"))
        XCTAssertEqual(answer.text, "你好 world"); XCTAssertNil(answer.task)
    }
    func testInterruptedSSEDoesNotInventCompletion() async {
        do { _ = try await provider("data: {\"choices\":[{\"delta\":{\"content\":\"部分\"}}]}\n\n").reply(to: input("hello")); XCTFail() }
        catch { XCTAssertEqual(error as? RitoCloudError, .incomplete) }
    }
    func testUnauthorizedErrorIsRedacted() async {
        do { _ = try await provider("{\"error\":{\"message\":\"secret-key-123\"}}", status: 401).reply(to: input("hello")); XCTFail() }
        catch { XCTAssertEqual(error as? RitoCloudError, .internalAccess); XCTAssertFalse(error.localizedDescription.contains("secret")) }
    }
    func testCloudPayloadExcludesAttachmentsAndPaths() throws {
        let f = RToolAIAttachment(id: UUID(), name: "PRIVATE.jpg", byteCount: 999)
        let body = try XCTUnwrap(provider("").makeRequest(input("hello", files: [f])).httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE")); XCTAssertFalse(text.contains(f.id.uuidString))
        XCTAssertTrue(text.contains("hello")); XCTAssertFalse(text.contains("test-key"))
    }
    func testHTTPSAndEmbeddedCredentialsValidation() {
        for url in ["http://example.com", "https://user:pass@example.com", "https://example.com?k=secret", "https://example.com#key"] {
            XCTAssertNil(RitoCustomAPIProvider.validEndpoint(url))
        }
        XCTAssertNotNil(RitoCustomAPIProvider.validEndpoint("https://api.deepseek.com/chat/completions"))
    }
    func testFilterRetainsSpacesOutsideReasoning() {
        var f = RitoTextFilter()
        XCTAssertEqual(f.append("<think>"), ""); XCTAssertEqual(f.append("hidden"), "")
        XCTAssertEqual(f.append("</think>\nHello "), "Hello "); XCTAssertEqual(f.append("world"), "world")
    }
    func testContextExcludesMockRepliesAndPreservesRealModeSwitchContext() throws {
        let old = [RToolAIMessage(id: UUID(), role: .assistant, text: "mock content", source: .mock),
                   RToolAIMessage(id: UUID(), role: .assistant, text: "real content", source: .local)]
        let context = try RitoConversationContext.messages(.init(messages: old, text: "next", attachments: [], intent: nil))
        XCTAssertFalse(context.contains { $0["content"] == "mock content" })
        XCTAssertTrue(context.contains { $0["content"] == "real content" })
        XCTAssertThrowsError(try RitoConversationContext.messages(input(String(repeating: "中", count: 2000))))
    }
    func testModelImportRejectsCorruptionAndDoesNotModifySource() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let bytes = Data("weights".utf8), file = source.appendingPathComponent("model.safetensors")
        try bytes.write(to: file)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let manifest = RitoModelManifest(repository: "Qwen/test", revision: "revision", files: [.init(name: file.lastPathComponent, bytes: Int64(bytes.count), sha256: sha)], totalBytes: Int64(bytes.count))
        let store = RitoModelStore(directory: root.appendingPathComponent("managed"))
        try store.importFiles(from: source, manifest: manifest); try store.verify(manifest)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        try Data("broken!".utf8).write(to: store.directory.appendingPathComponent(file.lastPathComponent))
        XCTAssertThrowsError(try store.verify(manifest))
        try store.importFiles(from: source, manifest: manifest); try store.verify(manifest)
    }
    func testModelStoreRejectsSymbolicLink() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("real"); try Data([1]).write(to: real)
        let link = root.appendingPathComponent("model")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        XCTAssertThrowsError(try RitoModelStore(directory: root).verify(.init(name: "model", bytes: 1, sha256: String(repeating: "0", count: 64))))
    }
    func testToolPlansRejectCommandsUnknownFilesAndWrongType() throws {
        let image = RToolAIAttachment(id: UUID(), name: "image.png", byteCount: 1)
        for op in ["run_shell", "pdf_merge", "organize_copy"] {
            let text = "{\"message\":\"test\",\"task\":{\"operation\":\"\(op)\",\"attachmentIDs\":[\"\(image.id)\"]}}"
            XCTAssertThrowsError(try RitoToolCall.decode(text, attachments: [image]))
        }
        let unknown = "{\"message\":\"test\",\"task\":{\"operation\":\"ocr\",\"attachmentIDs\":[\"\(UUID())\"]}}"
        XCTAssertThrowsError(try RitoToolCall.decode(unknown, attachments: [image]))
        let command = "{\"message\":\"test\",\"task\":{\"operation\":\"ocr\",\"attachmentIDs\":[\"\(image.id)\"],\"command\":\"rm\"}}"
        XCTAssertThrowsError(try RitoToolCall.decode(command, attachments: [image]))
        let valid = "{\"message\":\"test\",\"task\":{\"operation\":\"ocr\",\"attachmentIDs\":[\"\(image.id)\"]}}"
        XCTAssertEqual(try RitoToolCall.decode(valid, attachments: [image]).1?.operation, .ocr)
    }
    private func pdf(_ url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 100, height: 100)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages { context.beginPDFPage(nil); context.endPDFPage() }; context.closePDF()
    }
    func testPDFPreviewDoesNotWriteAndExecutionRetainsSources() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.pdf"), b = root.appendingPathComponent("b.pdf"), out = root.appendingPathComponent("merged.pdf")
        try pdf(a, pages: 2); try pdf(b, pages: 3)
        let original = try Data(contentsOf: a), idA = UUID(), idB = UUID()
        let call = RitoToolCall(operation: .pdf_merge, attachmentIDs: [idA, idB])
        let prepared = try RitoToolExecutor.prepare(call, files: [idA: a, idB: b], destination: out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        XCTAssertTrue(prepared.summary.contains { $0.contains("5 页") })
        _ = try await RitoToolExecutor.execute(prepared) { _ in }
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 5); XCTAssertEqual(try Data(contentsOf: a), original)
        do { _ = try await RitoToolExecutor.execute(prepared) { _ in }; XCTFail("No overwrite allowed") } catch { }
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 5)
    }
    func testPDFSourceChangeAfterPreviewStopsExecution() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.pdf"), b = root.appendingPathComponent("b.pdf"), out = root.appendingPathComponent("out.pdf")
        try pdf(a, pages: 1); try pdf(b, pages: 1); let ids = [UUID(), UUID()]
        let plan = try RitoToolExecutor.prepare(.init(operation: .pdf_merge, attachmentIDs: ids), files: [ids[0]: a, ids[1]: b], destination: out)
        try pdf(a, pages: 3)
        do { _ = try await RitoToolExecutor.execute(plan) { _ in }; XCTFail() } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }
    @MainActor func testSwitchProviderKeepsConversationAndCapabilities() async {
        let vm = RToolAIViewModel(responder: RToolAIMockService(replyDelay: .zero, stepDelay: .zero))
        vm.draft = "old"; vm.send()
        while vm.isBusy { await Task.yield() }
        let messages = vm.messages, id = vm.conversationID
        vm.updateResponder(RitoUnavailableProvider(source: .local, message: "missing"))
        XCTAssertEqual(vm.messages, messages); XCTAssertEqual(vm.conversationID, id); XCTAssertEqual(vm.serviceSource, .local)
        XCTAssertTrue(RitoLocalProvider().capabilities.offline)
    }
    func testFolderPreviewAndCopyPreserveSources() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("organized")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let a = source.appendingPathComponent("a.txt"), b = source.appendingPathComponent("b.png")
        try Data("document".utf8).write(to: a); try Data("image".utf8).write(to: b)
        let id = UUID()
        let plan = try RitoToolExecutor.prepare(.init(operation: .organize_copy, attachmentIDs: [id]), files: [id: source], destination: destination)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(plan.summary.contains { $0.contains("a.txt") && $0.contains("文档") })
        let results = try await RitoToolExecutor.execute(plan) { _ in }
        XCTAssertEqual(results.count, 2)
        let summary = RitoOrganizationSummary(results: results)
        XCTAssertEqual(summary.categories, [.init(name: "图片", count: 1), .init(name: "文档", count: 1)])
        XCTAssertEqual(summary.successCount, 2)
        XCTAssertTrue(results.allSatisfy { $0.organizationPhase == .completed })
        XCTAssertEqual(try Data(contentsOf: a), Data("document".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("文档/a.txt")), Data("document".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("图片/b.png")), Data("image".utf8))
    }

    @MainActor func testFirstUseModelIsUninstalledRatherThanFailed() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let manager = RitoModelManager(store: .init(directory: root))
        manager.check()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while manager.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(manager.busy); XCTAssertEqual(manager.phase, .uninstalled)
    }

}
