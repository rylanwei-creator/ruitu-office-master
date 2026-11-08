import AppKit
import Foundation
import Darwin
import MLX
import MLXLLM
import MLXLMCommon

@MainActor final class ProbeDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    var window: NSWindow?
    var label: NSTextField?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 210), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Rito MLX 兼容性验证"
        let label = NSTextField(wrappingLabelWithString: "正在验证 Metal 与 MLX…")
        label.frame = NSRect(x: 24, y: 24, width: 632, height: 160)
        window.contentView?.addSubview(label); window.center(); window.orderFront(nil)
        self.window = window; self.label = label
        Task.detached {
            do {
                typealias SandboxInit = @convention(c) (UnsafePointer<CChar>, UInt64, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
                guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "sandbox_init") else { throw NSError(domain: "Probe", code: 1) }
                let restrict = unsafeBitCast(symbol, to: SandboxInit.self)
                let sandboxResult = "(version 1)(allow default)(deny network*)".withCString { restrict($0, 0, nil) }
                guard sandboxResult == 0 else { throw NSError(domain: "Probe", code: 2) }
                var networkBlocked = false
                do { _ = try await URLSession.shared.data(from: URL(string: "https://huggingface.co")!) }
                catch { networkBlocked = true }
                guard networkBlocked else { throw NSError(domain: "Probe", code: 3) }
                setenv("MLX_METAL_FAST_SYNCH", "0", 1)
                Memory.cacheLimit = 64 * 1024 * 1024
                try withError { error in
                    let value = MLXArray([Float(1), Float(2), Float(3)])
                    try error.check()
                    let output = value * 2
                    try error.check()
                    eval(output)
                    try error.check()
                }
                await self.report("Metal / MLX 运算通过，正在加载 Qwen3 1.7B 4-bit…")
                guard let directoryPath = Bundle.main.object(forInfoDictionaryKey: "RitoModelDirectory") as? String else { throw NSError(domain: "Probe", code: 4) }
                let directory = URL(fileURLWithPath: directoryPath)
                let started = Date()
                var model: ModelContainer? = try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: directory))
                let loaded = Date().timeIntervalSince(started)
                var measurements: [[String: Any]] = []
                for round in 1...20 {
                    let container = model!
                    let input = try await container.prepare(input: UserInput(chat: [.system("你是 Rito，用简短中文回答。"), .user("列出五条详细的文件整理建议，每条至少两句话。/no_think")], additionalContext: ["enable_thinking": false]))
                    let generation = try await container.generate(input: input, parameters: .init(maxTokens: 256, maxKVSize: 2048, temperature: 0.3, prefillStepSize: 128))
                    var answer = "", chunks = 0
                    let generationStarted = Date()
                    for await event in generation {
                        if case .chunk(let text) = event { answer += text; chunks += 1 }
                    }
                    Memory.clearCache()
                    measurements.append(["round": round, "seconds": Date().timeIntervalSince(generationStarted), "chunks": chunks, "text": answer,
                                         "mlxActiveBytes": Memory.activeMemory, "mlxPeakBytes": Memory.peakMemory, "residentBytes": Self.residentBytes()])
                    await self.report("第 \(round)/20 轮真实生成完成：\(answer)\nMLX 活跃内存 \(Memory.activeMemory / 1048576) MB")
                }
                var cancelChunks = 0
                var recovered = ""
                do {
                    let container = model!
                    let (stream, producer) = try await container.perform { context in
                        let input = try await context.processor.prepare(input: UserInput(chat: [.user("详细解释文件分类，尽量多写。/no_think")], additionalContext: ["enable_thinking": false]))
                        let iterator = try TokenIterator(input: input, model: context.model, parameters: .init(maxTokens: 512, maxKVSize: 2048, prefillStepSize: 128))
                        return generateTask(promptTokenCount: input.text.tokens.size, modelConfiguration: context.configuration, tokenizer: context.tokenizer, iterator: iterator)
                    }
                    for await event in stream {
                        if case .chunk = event {
                            cancelChunks += 1
                            if cancelChunks == 3 { producer.cancel(); break }
                        }
                    }
                    await producer.value
                    let input = try await container.prepare(input: UserInput(chat: [.user("只回复恢复成功。/no_think")], additionalContext: ["enable_thinking": false]))
                    let recovery = try await container.generate(input: input, parameters: .init(maxTokens: 48, maxKVSize: 2048, prefillStepSize: 128))
                    for await event in recovery { if case .chunk(let text) = event { recovered += text } }
                    guard cancelChunks == 3, !recovered.isEmpty else { throw NSError(domain: "Probe", code: 5) }
                }
                model = nil; Memory.clearCache()
                let result: [String: Any] = ["status": "passed", "networkBlocked": networkBlocked, "cancelChunks": cancelChunks, "recoveryText": recovered, "loadSeconds": loaded, "physicalMemory": ProcessInfo.processInfo.physicalMemory,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString, "measurements": measurements, "afterUnloadBytes": Memory.activeMemory, "afterUnloadResidentBytes": Self.residentBytes()]
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: Self.resultURL)
                await self.report("MLX / Qwen3 原生验证通过：20 轮离线真实流式回答完成。模型已卸载。")
            } catch {
                try? JSONSerialization.data(withJSONObject: ["status": "failed", "error": error.localizedDescription]).write(to: Self.resultURL)
                await self.report("MLX 验证失败：\(error.localizedDescription)")
            }
        }
    }
    nonisolated static var resultURL: URL { URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "RitoResultPath") as? String ?? NSTemporaryDirectory() + "rito-mlx-probe.json") }
    nonisolated static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? info.resident_size : 0
    }
    func report(_ text: String) { label?.stringValue = text }
}
@main enum RitoMLXValidation {
    @MainActor static func main() { let app = NSApplication.shared; let delegate = ProbeDelegate()
        let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); app.mainMenu = menu
        app.delegate = delegate; app.run() }
}
