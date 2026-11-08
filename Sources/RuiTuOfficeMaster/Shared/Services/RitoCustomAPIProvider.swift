import Foundation

enum RitoCloudError: LocalizedError, Equatable {
    case notConfigured, invalidEndpoint, inputTooLong, quotaExhausted, rateLimited, internalAccess, unavailable, timeout, credentialTimeout, invalidModel, reasoningLimit, emptyResponse, invalidResponse, incomplete
    var errorDescription: String? {
        switch self {
        case .notConfigured: "请先配置自定义 API 地址、模型 ID 与密钥；普通工具不受影响"
        case .invalidEndpoint: "AI 地址必须是有效的 HTTPS 地址，不能包含账号、密码或查询参数"
        case .inputTooLong: "每条消息最多 2000 个字符，请缩短后再发送"
        case .quotaExhausted: "供应商 API 额度不足，请检查自己的账户；普通工具不受影响"
        case .rateLimited: "请求较频繁或服务正在忙，请稍后重试"
        case .internalAccess: "API 密钥无效或未授权，请检查服务商和密钥"
        case .unavailable: "AI 云端暂时不可用，普通办公工具仍可使用。可稍后重试或手动切换本地模型"
        case .timeout: "AI 请求超时，请稍后重试"
        case .credentialTimeout: "等待 macOS 钥匙串授权超时，尚未发送 AI 请求。请检查授权窗口或在 AI 设置重新保存密钥，再点击重试"
        case .invalidModel: "供应商不支持当前模型 ID 或请求参数，请在 AI 设置核对模型 ID"
        case .reasoningLimit: "模型返回了推理内容，但没有生成最终回答；请使用普通对话模式或关闭服务商的深度思考"
        case .emptyResponse: "服务已收到请求，但没有返回回答正文；自动兼容尝试也未获得正文，请稍后重试或在 AI 设置测试其他模型"
        case .invalidResponse: "AI 服务返回了无效响应，已停止读取"
        case .incomplete: "AI 回复中断，已保留收到的部分文字。可重新发送"
        }
    }
}

protocol RitoStreamingTransport: Sendable {
    func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, Int)
}

private final class RitoNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward credentials to a redirected host.
    }
}

struct RitoURLSessionTransport: RitoStreamingTransport {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 60
        config.httpShouldSetCookies = false; config.urlCache = nil; config.httpCookieStorage = nil
        return URLSession(configuration: config, delegate: RitoNoRedirect(), delegateQueue: nil)
    }()
    func open(_ request: URLRequest) async throws -> (AsyncThrowingStream<Data, Error>, Int) {
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RitoCloudError.invalidResponse }
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                do {
                    var line = Data(), totalBytes = 0
                    for try await byte in bytes {
                        try Task.checkCancellation(); line.append(byte); totalBytes += 1
                        guard totalBytes <= 524288 else { throw RitoCloudError.invalidResponse }
                        guard line.count <= 16384 else { throw RitoCloudError.invalidResponse }
                        if byte == 10 { continuation.yield(line); line.removeAll(keepingCapacity: true) }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http.statusCode)
    }
}

struct RitoCustomAPIProvider: RToolAIResponding {
        let endpoint: URL
    var authorization: String?
    var model: String?
    var transport: any RitoStreamingTransport = RitoURLSessionTransport()
    var responseTimeout: TimeInterval = 60
    var useJSONMode = true
    var source: RitoReplySource { .custom }
    var capabilities: AIProviderCapabilities { .init() }

    static func validEndpoint(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }
    func makeRequest(_ input: RToolAIRequest) throws -> URLRequest {
        guard Self.validEndpoint(endpoint.absoluteString) != nil else { throw RitoCloudError.invalidEndpoint }
        guard input.text.count <= 2000, !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RitoCloudError.inputTooLong }
        let messages = try RitoConversationContext.messages(input, byteLimit: 6000)
        // Attachments, file names, sizes, paths, intents and simulated tasks are deliberately excluded.
        var body: [String: Any] = ["messages": messages]
        do {
            guard let model, !model.isEmpty, model.count <= 120 else { throw RitoCloudError.notConfigured }
            body["model"] = model; body["stream"] = true; body["max_tokens"] = 1024
            if input.expectsToolPlan { body["max_tokens"] = 2048 }
            if endpoint.host?.lowercased() == "api.deepseek.com" {
                body["thinking"] = ["type":"disabled"]
                if input.expectsToolPlan && useJSONMode { body["response_format"] = ["type":"json_object"] }
            }
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let authorization { request.setValue("Bearer " + authorization, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    func reply(to request: RToolAIRequest) async throws -> RToolAIReply { try await receive(request, delta: nil) }
    func stream(to request: RToolAIRequest, delta: @escaping @MainActor @Sendable (String) -> Void) async throws -> RToolAIReply {
        try await receive(request, delta: delta)
    }
    private func receive(_ input: RToolAIRequest, delta: (@MainActor @Sendable (String) -> Void)?) async throws -> RToolAIReply {
        try await RitoAsyncDeadline.run(seconds:responseTimeout) {
            do { return try await receiveBounded(input,delta:delta) }
            catch RitoCloudError.emptyResponse {
                try Task.checkCancellation()
                await input.progress?(.recoveringEmptyReply)
                RitoRequestTrace.event("empty_reply_recovery",count:1,flush:true)
                // Some compatible models return only whitespace in forced JSON mode.
                // One fresh text-mode generation, still strictly validated by OfficeProvider.
                var compatible = self; compatible.useJSONMode = false
                let retry = RToolAIRequest(messages:input.expectsToolPlan && !input.continuesAttachmentTask ? [] : input.messages,
                    text:input.text,attachments:input.attachments,intent:input.intent,
                    toolInstructions:input.toolInstructions,progress:input.progress,expectsToolPlan:input.expectsToolPlan,
                    continuesAttachmentTask:input.continuesAttachmentTask)
                return try await compatible.receiveBounded(retry,delta:delta)
            }
        }
    }
    private func receiveBounded(_ input: RToolAIRequest, delta: (@MainActor @Sendable (String) -> Void)?) async throws -> RToolAIReply {
        do {
            RitoRequestTrace.event("request_open",flush:true)
            await input.progress?(.connecting)
            let (stream, status) = try await openWithRecovery(makeRequest(input), input:input)
            RitoRequestTrace.event("headers_received",status:status,flush:true)
            await input.progress?(.receiving)
            if status != 200 {
                var data = Data()
                for try await chunk in stream { data.append(chunk); if data.count > 16384 { break } }
                let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let code = (object?["error"] as? [String: Any])?["code"] as? String
                throw mapped(code, status: status)
            }
            var buffer = Data(), text = "", completed = false, reasoning = false, filter = RitoTextFilter()
            for try await chunk in stream {
                try Task.checkCancellation()
                buffer.append(chunk)
                guard buffer.count <= 65536 else {
                    RitoRequestTrace.event("protocol_buffer_limit",count:1,flush:true);throw RitoCloudError.invalidResponse
                }
                // Split on blank lines as bytes: multibyte Chinese characters may span network packets.
                while let boundary = buffer.range(of: Data([10, 10])) ?? buffer.range(of: Data([13, 10, 13, 10])) {
                    let packet = Data(buffer[..<boundary.lowerBound]); buffer.removeSubrange(..<boundary.upperBound)
                    guard let event = String(data: packet, encoding: .utf8) else { throw RitoCloudError.invalidResponse }
                    if event.hasPrefix(":") {
                        RitoRequestTrace.event("keep_alive_packets",count:1)
                        await input.progress?(.waitingForModel)
                    }
                    let payload = event.components(separatedBy: .newlines).filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
                    if payload.isEmpty { continue }
                    if payload == "[DONE]" { completed = true; break }
                    guard let data = payload.data(using: .utf8),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                        RitoRequestTrace.event("protocol_invalid_json",count:1,flush:true);throw RitoCloudError.invalidResponse
                    }
                    if let error = object["error"] as? [String: Any] { throw mapped(error["code"] as? String, status: 503) }
                    RitoRequestTrace.event("sse_packets",count:1)
                    if object["done"] as? Bool == true { completed = true; break }
                    var piece = object["delta"] as? String
                    if let choices = object["choices"] as? [[String: Any]], let content = choices.first?["delta"] as? [String: Any] {
                        piece = content["content"] as? String
                        if piece == nil { RitoRequestTrace.event("nontext_delta_packets",count:1) }
                        else if piece!.isEmpty { RitoRequestTrace.event("empty_content_packets",count:1) }
                        if let hidden = content["reasoning_content"] as? String, !hidden.isEmpty {
                            reasoning = true; RitoRequestTrace.event("reasoning_packets",count:1)
                            await input.progress?(.reasoning)
                        }
                    }
                    if let piece, !piece.isEmpty {
                        RitoRequestTrace.event("raw_content_characters",count:piece.count)
                        if piece.allSatisfy(\.isWhitespace) { RitoRequestTrace.event("whitespace_characters",count:piece.count) }
                        let visible = filter.append(piece)
                        text += visible; guard text.count <= 6000 else { throw RitoCloudError.invalidResponse }
                        if !visible.isEmpty { RitoRequestTrace.event("visible_characters",count:visible.count) }
                        if let delta, !visible.isEmpty { await delta(visible) }
                    }
                    if let choices = object["choices"] as? [[String:Any]], let finish = choices.first?["finish_reason"] as? String {
                        if finish == "stop" { completed = true; break }
                        if !finish.isEmpty { throw reasoning && text.isEmpty ? RitoCloudError.reasoningLimit : RitoCloudError.incomplete }
                    }
                }
                if completed { break }
            }
            try Task.checkCancellation()
            guard completed else { throw RitoCloudError.incomplete }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw reasoning ? RitoCloudError.reasoningLimit : RitoCloudError.emptyResponse }
            RitoRequestTrace.event("cloud_completed",flush:true)
            return .init(text: text, task: nil)
        } catch is CancellationError { throw CancellationError() }
        catch let error as RitoCloudError { throw error }
        catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw error.code == .timedOut ? RitoCloudError.timeout : RitoCloudError.unavailable
        } catch { throw RitoCloudError.invalidResponse }
    }
    private func openWithRecovery(_ request: URLRequest, input: RToolAIRequest) async throws -> (AsyncThrowingStream<Data, Error>, Int) {
        do { return try await transport.open(request) }
        catch let error as URLError where [.cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed].contains(error.code) {
            // One reconnect before headers only. Never replay a partially streamed answer,
            // HTTP rejection, authorization failure or ambiguous full-response timeout.
            try Task.checkCancellation()
            await input.progress?(.reconnecting)
            RitoRequestTrace.event("connection_retry",count:1,flush:true)
            try await Task.sleep(for:.milliseconds(500))
            try Task.checkCancellation()
            return try await transport.open(request)
        }
    }
    private func mapped(_ code: String?, status: Int) -> RitoCloudError {
        switch code {
        case "daily_quota_exhausted", "ip_daily_limit": .quotaExhausted
        case "rate_limited", "service_busy": .rateLimited
        case "input_too_long", "invalid_request": .inputTooLong
        case "timeout": .timeout
        case "internal_access_required": .internalAccess
        case "model_not_found", "invalid_model", "unsupported_model": .invalidModel
        default: status == 400 || status == 404 ? .invalidModel : status == 402 ? .quotaExhausted : status == 429 ? .rateLimited : ([401, 403].contains(status) ? .internalAccess : .unavailable)
        }
    }
}
