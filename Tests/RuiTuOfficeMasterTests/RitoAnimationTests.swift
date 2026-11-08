import XCTest
import AppKit
@testable import RuiTuOfficeMaster

final class RitoAnimationTests: XCTestCase, @unchecked Sendable {
    func testSpeakingHasThreeMouthFramesAndBlinkUsesEyeFrame() {
        let frames = (0..<100).map { RitoSpriteAnimator.frame(state: .speaking, elapsed: Double($0) * 0.1, reduceMotion: false) }
        XCTAssertEqual(Set(frames.map(\.mouth)), [0, 1, 2])
        XCTAssertTrue(frames.contains { $0.eyes == 1 })
        XCTAssertEqual(RitoSpriteAnimator.frame(state: .blinking, elapsed: 0.1, reduceMotion: false).eyes, 1)
        XCTAssertEqual(RitoSpriteAnimator.frame(state: .blinking, elapsed: 0.3, reduceMotion: false).eyes, 0)
    }
    func testReduceMotionAndFeedbackAreFinite() {
        for state in RitoAnimationState.allCases {
            let frame = RitoSpriteAnimator.frame(state: state, elapsed: 0.3, reduceMotion: true)
            XCTAssertEqual(frame.offset, 0); XCTAssertEqual(frame.angle, 0); XCTAssertEqual(frame.mouth, 0)
        }
        for state in [RitoAnimationState.success, .error] {
            let frame = RitoSpriteAnimator.frame(state: state, elapsed: 2, reduceMotion: false)
            XCTAssertNil(frame.decoration); XCTAssertEqual(frame.offset, 0); XCTAssertEqual(frame.eyes, 0)
        }
    }
    func testBlinkRepeatsEveryFourSecondsWithoutProlongedClosure() {
        for cycle in 0..<15 {
            let start = Double(cycle) * 4
            XCTAssertEqual(RitoSpriteAnimator.frame(state: .idle, elapsed: start + 3.9, reduceMotion: false).eyes, 1)
            XCTAssertEqual(RitoSpriteAnimator.frame(state: .idle, elapsed: start + 0.2, reduceMotion: false).eyes, 0)
            XCTAssertEqual(RitoSpriteAnimator.frame(state: .idle, elapsed: start + 3.5, reduceMotion: false).eyes, 0)
        }
    }
    func testHoverGreetingEndsAndDoesNotOverrideSpeakingOrReducedMotion() {
        let resting = RitoSpriteAnimator.frame(state: .idle, elapsed: 1, reduceMotion: false)
        let greeting = RitoSpriteAnimator.frame(state: .idle, elapsed: 1, reduceMotion: false, hoverElapsed: 0.35)
        XCTAssertEqual(greeting.offset, resting.offset - 9, accuracy: 0.001)
        XCTAssertEqual(RitoSpriteAnimator.frame(state: .idle, elapsed: 1, reduceMotion: false, hoverElapsed: 1), resting)
        let speaking = RitoSpriteAnimator.frame(state: .speaking, elapsed: 1, reduceMotion: false)
        XCTAssertEqual(RitoSpriteAnimator.frame(state: .speaking, elapsed: 1, reduceMotion: false, hoverElapsed: 0.35), speaking)
        let reduced = RitoSpriteAnimator.frame(state: .idle, elapsed: 1, reduceMotion: true, hoverElapsed: 0.35)
        XCTAssertEqual(reduced.offset, 0); XCTAssertEqual(reduced.angle, 0)
    }
    @MainActor func testGreetingCooldownAndStatePriority() {
        let controller = RitoAnimationController(), time = Date()
        XCTAssertTrue(controller.greet(at: time))
        XCTAssertFalse(controller.greet(at: time.addingTimeInterval(0.4)))
        XCTAssertTrue(controller.greet(at: time.addingTimeInterval(1.3)))
        controller.set(.speaking)
        XCTAssertNil(controller.hoverStartedAt)
        XCTAssertFalse(controller.greet(at: time.addingTimeInterval(3)))
        controller.set(.idle)
        XCTAssertTrue(controller.greet(at: time.addingTimeInterval(4)))
        controller.clearGreeting()
        XCTAssertNil(controller.hoverStartedAt)
    }
    @MainActor func testRegisteredAssetsHaveDistinctMouthsAndImmutableBody() async throws {
        let start = Date()
        await RitoAnimationAssets.prepare()
        XCTAssertEqual(RitoAnimationAssets.frames.count, 12)
        print("Rito asset cold initialization: \(Date().timeIntervalSince(start)) seconds")
        let frames = try (0...2).map { mouth -> CGImage in
            let image = try XCTUnwrap(RitoAnimationAssets.image(mouth: mouth, eyes: 0))
            return try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
        XCTAssertEqual(Set(frames.map(\.width)), [1254]); XCTAssertEqual(Set(frames.map(\.height)), [1254])
        func rgba(_ image: CGImage) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: try XCTUnwrap(context.data), count: image.width * image.height * 4)
        }
        let data = try frames.map(rgba)
        XCTAssertNotEqual(data[0], data[1]); XCTAssertNotEqual(data[1], data[2])
        // Compare every pixel outside the calibrated mouth rectangle, not just an asset name.
        for frame in data.dropFirst() {
            var changed = 0
            for y in 0..<1254 { for x in 0..<1254 {
                let offset = (y * 1254 + x) * 4
                if frame[offset..<offset+4] != data[0][offset..<offset+4] {
                    changed += 1
                    XCTAssertTrue((596..<708).contains(x) && (832..<890).contains(y), "Unrelated body pixel changed at \(x),\(y)")
                }
            } }
            XCTAssertGreaterThan(changed, 100)
        }
        // QA render uses exactly the application's cached frames; no source-image redraw.
        let context = try XCTUnwrap(CGContext(data: nil, width: 768, height: 256, bitsPerComponent: 8, bytesPerRow: 768 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 768, height: 256))
        context.interpolationQuality = .none
        for index in 0..<3 { context.draw(frames[index], in: CGRect(x: index * 256, y: 0, width: 256, height: 256)) }
        let preview = try XCTUnwrap(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: preview)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rito-animation-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("mouth-preview.png"))

    }

    @MainActor func testBlinkRemovesOpenEyeInkAndPreservesCheeks() async throws {
        await RitoAnimationAssets.prepare()
        let original = try XCTUnwrap(RitoAnimationAssets.image(mouth: 0, eyes: 0)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let blink = try XCTUnwrap(RitoAnimationAssets.image(mouth: 0, eyes: 1)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let before = NSBitmapImageRep(cgImage: original), after = NSBitmapImageRep(cgImage: blink)
        for x0 in [498, 738] {
            var closedInk = 0
            for y in 719..<859 { for x in x0..<x0+72 {
                let color = try XCTUnwrap(after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                if max(color.redComponent, color.greenComponent, color.blueComponent) < 0.5 {
                    closedInk += 1
                    XCTAssertTrue((784..<802).contains(y), "Original open-eye edge remains at \(x),\(y)")
                }
            } }
            XCTAssertGreaterThan(closedInk, 200)
        }
        // Both cheeks, the mouth and surrounding face must remain identical.
        for rect in [CGRect(x: 456, y: 844, width: 47, height: 38), CGRect(x: 806, y: 844, width: 42, height: 38), CGRect(x: 590, y: 820, width: 130, height: 75)] {
            for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) {
                XCTAssertEqual(before.colorAt(x: x, y: y), after.colorAt(x: x, y: y))
            } }
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 1024, height: 256, bitsPerComponent: 8, bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1024, height: 256))
        context.interpolationQuality = .none
        for index in 0...3 {
            let frame = try XCTUnwrap(RitoAnimationAssets.image(mouth: 0, eyes: index)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            context.draw(frame, in: CGRect(x: index * 256, y: 0, width: 256, height: 256))
        }
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage()))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rito-animation-qa", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("eye-preview.png"))
    }

    private actor StreamGate: RToolAIResponding {
        var emitted = false
        var continuation: CheckedContinuation<Void, Never>?
        func reply(to request: RToolAIRequest) async throws -> RToolAIReply { .init(text: "unused", task: nil) }
        func stream(to request: RToolAIRequest, delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
            await delta("第一段"); emitted = true
            await withCheckedContinuation { continuation = $0 }
            // Deliberately hostile late provider callback, even after cancellation.
            await delta("不应出现")
            return .init(text: "不应覆盖部分回复", task: nil)
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    @MainActor func testStreamOnlyAnimatesCurrentMessageAndStopRejectsLateChunks() async throws {
        let gate = StreamGate(), fast = RToolAIMockService(replyDelay: .zero, stepDelay: .zero)
        let model = RToolAIViewModel(responder: gate, simulator: fast)
        model.draft = "第一问"; model.send()
        XCTAssertFalse(model.generatingText); XCTAssertEqual(model.activity, .replying)
        while !(await gate.emitted) { await Task.yield() }
        let message = try XCTUnwrap(model.messages.last)
        XCTAssertEqual(message.text, "第一段"); XCTAssertEqual(model.mascotState(for: message), .speaking)
        model.stop()
        XCTAssertFalse(model.generatingText); XCTAssertNil(model.activeReplyID)
        XCTAssertEqual(model.mascotState(for: message), .idle)
        await gate.release(); for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.messages.last?.text, "第一段")
    }
    @MainActor func testRenamePersistsAcrossSendsAndLegacyHistoryDecodes() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rito-test-\(UUID())"))
        let fast = RToolAIMockService(replyDelay: .zero, stepDelay: .zero)
        let model = RToolAIViewModel(responder: fast, simulator: fast, historyStore: .init(defaults: defaults))
        model.draft = "你好"; model.send(); while model.isBusy { await Task.yield() }
        model.renameConversation(model.conversationID, title: "我的办公计划")
        model.draft = "继续"; model.send(); while model.isBusy { await Task.yield() }
        XCTAssertEqual(model.conversations.first?.title, "我的办公计划")
        XCTAssertEqual(RitoAIHistoryStore(defaults: defaults).load().first?.title, "我的办公计划")
        let legacy = try JSONEncoder().encode(model.conversations)
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: legacy) as? [[String: Any]])
        objects[0].removeValue(forKey: "customTitle")
        let restored = try JSONDecoder().decode([RitoAIConversation].self, from: JSONSerialization.data(withJSONObject: objects))
        XCTAssertEqual(restored.first?.title, "你好")
        let assistants = model.messages.filter { $0.role == .assistant }
        XCTAssertTrue(assistants.allSatisfy { model.mascotState(for: $0) == .idle })
    }
    @MainActor func testTaskStatePriorityCancelRetryAndSuccessFeedback() async throws {
        let fast = RToolAIMockService(replyDelay: .zero, stepDelay: .zero)
        let model = RToolAIViewModel(responder: fast, simulator: fast)
        model.choose(.organize); model.send(); while model.isBusy { await Task.yield() }
        let id = try XCTUnwrap(model.messages.last?.task?.id)
        model.confirm(id)
        XCTAssertEqual(model.mascotState(for: try XCTUnwrap(model.messages.last)), .working)
        model.dismiss(id)
        XCTAssertEqual(model.messages.last?.task?.state, .cancelled)
        XCTAssertEqual(model.mascotState(for: try XCTUnwrap(model.messages.last)), .idle)
        model.retry(id)
        XCTAssertEqual(model.messages.last?.task?.state, .awaitingConfirmation)
        model.confirm(id); while model.isBusy { await Task.yield() }
        XCTAssertEqual(model.mascotState(for: try XCTUnwrap(model.messages.last)), .success)
        model.newConversation(); XCTAssertNil(model.feedbackMessageID)
    }
}
