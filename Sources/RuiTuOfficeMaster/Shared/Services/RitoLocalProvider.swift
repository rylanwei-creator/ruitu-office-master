import Foundation
import MLX
import MLXLLM
import MLXLMCommon

actor RitoLocalEngine {
    static let shared = RitoLocalEngine()
    private var model: ModelContainer?
    private var busy = false
    private var unloadRequested = false
    private var generation: Task<Void, Never>?
    private let store: RitoModelStore
    init(store: RitoModelStore = .standard) { self.store = store }
    func unload() {
        unloadRequested = true; generation?.cancel()
        if !busy, model != nil { model = nil; Memory.clearCache() }
    }
    func generate(_ request: RToolAIRequest, delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
        try await withError { @Sendable [self] in try await self.generateIsolated(request, delta: delta) }
    }
    private func generateIsolated(_ request: RToolAIRequest, delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
        guard !busy else { throw RitoModelError.busy }
        busy = true; unloadRequested = false
        RitoRequestTrace.event("local_loading",flush:true)
        defer {
            generation = nil; busy = false
            if model != nil { Memory.clearCache() }
            if unloadRequested, model != nil { model = nil; Memory.clearCache() }
        }
            if model == nil {
                let manifest = try RitoModelManifest.bundled()
                let check = Task.detached { [store] in try store.verify(manifest) }
                try await withTaskCancellationHandler { try await check.value } onCancel: { check.cancel() }
                try Task.checkCancellation()
                // Upstream supports macOS 14 SharedEvent synchronization; fast sync needs 15+.
                setenv("MLX_METAL_FAST_SYNCH", "0", 1)
                Memory.cacheLimit = 64 * 1024 * 1024
                model = try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: store.directory))
            }
            try Task.checkCancellation()
            guard let model else { throw RitoModelError.missing }
            let messages = try RitoConversationContext.messages(request)
            let (stream, producer) = try await model.perform { context in
                let chat: [Chat.Message] = messages.map { item in
                    switch item["role"] {
                    case "system": .system(item["content"] ?? "")
                    case "assistant": .assistant(item["content"] ?? "")
                    default: .user(item["content"] ?? "")
                    }
                }
                let prepared = try await context.processor.prepare(input: UserInput(chat: chat, additionalContext: ["enable_thinking": false]))
                // This pinned Qwen3 template ignores enable_thinking. Prefill the empty thinking
                // block explicitly so generation starts with the final answer, not hidden reasoning.
                let suffix = MLXArray(context.tokenizer.encode(text:"<think>\n\n</think>\n\n"))
                let input = LMInput(tokens:concatenated([prepared.text.tokens,suffix],axis:0))
                RitoRequestTrace.event("local_prompt_tokens",count:input.text.tokens.size,flush:true)
                guard input.text.tokens.size <= 1536 else { throw RitoModelError.inputLimit }
                let iterator = try TokenIterator(input: input, model: context.model,
                    parameters: .init(maxTokens: 512, maxKVSize: 2048, temperature: 0.6, topP: 0.8, topK: 20, prefillStepSize: 128))
                return generateTask(promptTokenCount: input.text.tokens.size, modelConfiguration: context.configuration,
                                    tokenizer: context.tokenizer, iterator: iterator)
            }
            generation = producer
            var answer = "", filter = RitoTextFilter()
            do { try await withTaskCancellationHandler {
                for await event in stream {
                    try Task.checkCancellation()
                    if case .chunk(let raw) = event {
                        RitoRequestTrace.event("local_raw_chunks",count:1)
                        let piece = filter.append(raw)
                        if !piece.isEmpty { RitoRequestTrace.event("visible_characters",count:piece.count) }
                        if !piece.isEmpty { answer += piece; await delta(piece) }
                    }
                }
                await producer.value
                try Task.checkCancellation()
            } onCancel: { producer.cancel() }
            } catch { producer.cancel(); await producer.value; throw error }
            guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RitoModelError.empty }
            RitoRequestTrace.event("local_completed",flush:true)
            return .init(text: answer, task: nil)
    }
}

struct RitoLocalProvider: AIProvider {
    let engine: RitoLocalEngine
    init(engine: RitoLocalEngine = .shared) { self.engine = engine }
    var source: RitoReplySource { .local }
    var capabilities: AIProviderCapabilities { .init(offline: true) }
    func reply(to request: RToolAIRequest) async throws -> RToolAIReply { try await engine.generate(request) { _ in } }
    func stream(to request: RToolAIRequest, delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
        try await engine.generate(request, delta: delta)
    }
}
