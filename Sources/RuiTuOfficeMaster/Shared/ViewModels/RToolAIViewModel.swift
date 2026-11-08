import Foundation
import AppKit
import Observation

@MainActor @Observable
final class RToolAIViewModel {
    enum Activity { case idle, replying, executing }
    var draft = ""
    private(set) var messages: [RToolAIMessage] = []
    private(set) var attachments: [RToolAIAttachment] = []
    private(set) var activity: Activity = .idle
    private(set) var currentToolID: UUID?
    private(set) var activeReplyID: UUID?
    private(set) var generatingText = false
    private(set) var replyStatus = "Rito 正在思考…"
    private(set) var feedbackMessageID: UUID?
    private(set) var feedbackState: RitoAnimationState = .idle
    @ObservationIgnored private var feedbackWork: Task<Void, Never>?
    private(set) var notice: String?
    private(set) var canRetryReply = false
    @ObservationIgnored private var failedRequest: RToolAIRequest?
    @ObservationIgnored private var failedUserID: UUID?
    @ObservationIgnored private var failedNoticeID: UUID?
    @ObservationIgnored private let destinationPicker: @MainActor () async -> URL?
    @ObservationIgnored private var failedFiles: [UUID: URL] = [:]
    private(set) var isChoosingFiles = false
    private(set) var conversationID = UUID()
    private(set) var conversations: [RitoAIConversation] = []
    @ObservationIgnored private let historyStore: RitoAIHistoryStore?
    private var selectedIntent: RToolAIIntent?
    @ObservationIgnored private var attachmentURLs: Set<URL> = []
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var operationID = UUID()
    @ObservationIgnored private var responder: any RToolAIResponding
    private(set) var serviceSource: RitoReplySource
    @ObservationIgnored private let simulator: any RToolAITaskSimulating
    static let attachmentLimit = 8
    var isBusy: Bool { activity != .idle }
    var canSend: Bool { !isBusy && !isChoosingFiles && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(responder: any RToolAIResponding = RToolAIMockService(),
         simulator: any RToolAITaskSimulating = RToolAIMockService(),
         historyStore: RitoAIHistoryStore? = nil,
         destinationPicker: @escaping @MainActor () async -> URL? = RToolAIViewModel.chooseDestination) {
        self.responder = responder
        self.serviceSource = responder.source
        self.simulator = simulator
        self.historyStore = historyStore
        self.destinationPicker = destinationPicker
        self.conversations = historyStore?.load() ?? []
    }
    var serviceTitle: String {
        switch serviceSource { case .local: "本地免费 AI"; case .custom, .cloud: "自定义云端 API"; case .mock: "演示模式" }
    }
    func updateResponder(_ responder: any AIProvider) {
        if isBusy { stop() }
        if serviceSource == .local && responder.source != .local { Task { await RitoLocalEngine.shared.unload() } }
        self.responder = responder; serviceSource = responder.source
    }

    func choose(_ intent: RToolAIIntent) {
        guard !isBusy else { return }
        selectedIntent = intent
        draft = intent.prompt
        notice = nil
    }

    func addAttachments(_ urls: [URL]) {
        guard !isBusy else { return }
        var skipped = 0
        for url in urls {
            let normalized = url.standardizedFileURL
            guard url.isFileURL, !attachmentURLs.contains(normalized) else { skipped += 1; continue }
            guard attachments.count < Self.attachmentLimit else { skipped += 1; continue }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]), values.isRegularFile == true || values.isDirectory == true else {
                skipped += 1; continue
            }
            let attachment = RToolAIAttachment(id: UUID(), name: url.lastPathComponent, byteCount: Int64(values.isDirectory == true ? 0 : values.fileSize ?? 0), isDirectory: values.isDirectory)
            attachments.append(attachment)
            attachmentPaths[attachment.id] = normalized
            attachmentURLs.insert(normalized)
            if RitoImagePreview.isImage(attachment.name) {
                let id = attachment.id
                Task { [weak self] in
                    let data = await Task.detached { RitoImagePreview.data(from: normalized) }.value
                    guard let self, let data else { return }
                    self.storeAttachmentPreview(data, id: id)
                }
            }
        }
        notice = skipped > 0 ? "已跳过 \(skipped) 个重复、不可用或超出上限的文件；每条消息最多 \(Self.attachmentLimit) 个附件。" : nil
    }

    private func storeAttachmentPreview(_ data: Data, id: UUID) {
        if let i = attachments.firstIndex(where: { $0.id == id }) { attachments[i].previewData = data }
        for m in messages.indices {
            if let i = messages[m].attachments.firstIndex(where: { $0.id == id }) {
                messages[m].attachments[i].previewData = data; saveConversation()
            }
        }
    }

    func choosePreview(attachmentID: UUID? = nil, taskID: UUID? = nil, resultID: UUID? = nil) async {
        guard !isBusy, !isChoosingFiles else { return }
        isChoosingFiles = true
        defer { isChoosingFiles = false }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "补充预览"
        panel.message = "请选择这条记录对应的原图片。只生成本机缩略图，不重新识别、不上传；原识别文字保留。"
        guard await FileDialogs.response(to: panel) == .OK, let url = panel.url else { return }
        let expected = attachmentID.flatMap { id in messages.flatMap(\.attachments).first { $0.id == id }?.name }
            ?? taskID.flatMap { id in messages.first { $0.task?.id == id }?.task?.results.first { $0.id == resultID }?.sourceName }
        guard url.lastPathComponent == expected else { notice = "所选图片的文件名与这条记录不一致，请选择对应原图片。"; return }
        guard let data = await Task.detached(operation: { RitoImagePreview.data(from: url) }).value else {
            notice = "无法生成图片预览，请检查文件是否仍可读取。"; return
        }
        if let attachmentID { storeAttachmentPreview(data, id: attachmentID) }
        if let taskID, let m = messages.firstIndex(where: { $0.task?.id == taskID }),
           let i = messages[m].task?.results.firstIndex(where: { $0.id == resultID }) {
            messages[m].task?.results[i].previewData = data
        }
        notice = nil; saveConversation()
    }

    func chooseResultFile(taskID: UUID, resultID: UUID) async {
        guard !isBusy, !isChoosingFiles, let m = messages.firstIndex(where: { $0.task?.id == taskID }),
              messages[m].task?.liveCall?.operation == .pdf_merge,
              let i = messages[m].task?.results.firstIndex(where: { $0.id == resultID }),
              let name = messages[m].task?.results[i].sourceName else { return }
        isChoosingFiles = true
        defer { isChoosingFiles = false }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]; panel.canChooseFiles = true
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "关联结果文件"
        panel.message = "选择对应的已生成 PDF：\(name)。只关联本机文件，不重新合并、不上传。"
        guard await FileDialogs.response(to: panel) == .OK, let url = panel.url else { return }
        guard url.lastPathComponent == name else { notice = "文件名与这条 PDF 结果不一致，请选择对应文件。"; return }
        do {
            let file = try await Task.detached {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try PDFService().validate(url: url)
                return RitoResultFile.capture(url)
            }.value
            messages[m].task?.results[i].fileReference = file
            notice = nil; saveConversation()
        } catch { notice = error.localizedDescription }
    }

    func removeAttachment(_ id: UUID) {
        guard !isBusy else { return }
        // Names may be identical in different directories; keep identity-based removals.
        if let index = attachments.firstIndex(where: { $0.id == id }) {
            attachments.remove(at: index)
            // Rebuild deduplication from a parallel identity map instead of guessing a path.
            attachmentPaths.removeValue(forKey: id)
            attachmentURLs = Set(attachmentPaths.values)
        }
    }

    @ObservationIgnored private var attachmentPaths: [UUID: URL] = [:]
    private struct PendingAttachments {
        let messageID: UUID
        let attachments: [RToolAIAttachment]
        let files: [UUID: URL]
        let intent: RToolAIIntent?
    }
    private var pendingAttachments: [UUID: PendingAttachments] = [:]
    var continuingAttachments: [RToolAIAttachment] {
        pendingAttachments[conversationID]?.attachments ?? []
    }
    func clearContinuingAttachments() {
        guard !isBusy else { return }
        pendingAttachments.removeValue(forKey: conversationID)
        canRetryReply = false; failedRequest = nil; failedFiles = [:]; failedUserID = nil; failedNoticeID = nil
        notice = nil
    }
    @ObservationIgnored private var toolFiles: [UUID: [UUID: URL]] = [:]
    @ObservationIgnored private var preparedTools: [UUID: RitoPreparedTool] = [:]

    func chooseFiles() async {
        guard !isBusy && !isChoosingFiles else { return }
        isChoosingFiles = true
        defer { isChoosingFiles = false }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "添加附件"
        panel.message = "选择图片、PDF 或待整理文件夹。AI 仅获得附件 ID 与类型，不上传内容；生成预览并确认后才会本机处理。"
        guard await FileDialogs.response(to: panel) == .OK else { return }
        addAttachments(panel.urls)
    }

    func send() {
        guard canSend else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = selectedIntent.flatMap { text == $0.prompt ? $0 : nil }
        let userID = UUID()
        if !attachments.isEmpty {
            pendingAttachments[conversationID] = .init(messageID: userID, attachments: attachments, files: attachmentPaths, intent: intent)
        }
        let pending = pendingAttachments[conversationID]
        let origin = pending.flatMap { batch in messages.firstIndex { $0.id == batch.messageID } }
        let history = origin.map { Array(messages[$0...]) } ?? messages
        let request = RToolAIRequest(messages: history, text: text,
            attachments: pending?.attachments ?? [], intent: intent ?? pending?.intent,
            continuesAttachmentTask: origin != nil)
        let selectedFiles = pending?.files ?? [:]
        messages.append(.init(id: userID, role: .user, text: text, attachments: attachments))
        saveConversation()
        draft = ""; attachments = []; attachmentURLs = []; attachmentPaths = [:]; selectedIntent = nil; notice = nil
        beginReply(request, selectedFiles: selectedFiles, userID: userID)
    }

    func retryReply() {
        guard canRetryReply, !isBusy, !isChoosingFiles, let request = failedRequest, let userID = failedUserID else { return }
        if let id = failedNoticeID { messages.removeAll { $0.id == id } }
        beginReply(request, selectedFiles: failedFiles, userID: userID)
    }

    private func beginReply(_ request: RToolAIRequest, selectedFiles: [UUID: URL], userID: UUID) {
        if let i = messages.firstIndex(where: { $0.id == userID }) { messages[i].replyIssue = nil }
        failedUserID = nil
        failedNoticeID = nil
        canRetryReply = false; failedRequest = nil; failedFiles = [:]; notice = nil
        clearFeedback()
        activity = .replying; activeReplyID = nil; generatingText = false
        let token = UUID(); operationID = token
        let responder = self.responder
        let replySource = responder.source
        RitoRequestTrace.begin(replySource)
        let replyID = UUID()
        replyStatus = replySource == .local ? "正在准备本地模型或思考…" : "正在准备 AI 请求…"
        var streamingRequest = request
        streamingRequest.progress = { [weak self] phase in
            guard let self, self.operationID == token, self.activity == .replying else { return }
            self.replyStatus = phase.title
        }
        let preparedRequest = streamingRequest
        work = Task { [weak self] in
            do {
                let reply = try await responder.stream(to: preparedRequest) { [weak self] chunk in
                    guard let self, self.operationID == token, self.activity == .replying, !chunk.isEmpty else { return }
                    if let index = self.messages.firstIndex(where: { $0.id == replyID }) {
                        self.messages[index].text += chunk
                    } else {
                        self.messages.append(.init(id: replyID, role: .assistant, text: chunk, source: replySource))
                    }
                    self.activeReplyID = replyID; self.generatingText = true
                }
                try Task.checkCancellation()
                guard let self, self.operationID == token else { return }
                if let index = self.messages.firstIndex(where: { $0.id == replyID }) {
                    self.messages[index].text = reply.text
                    self.messages[index].task = reply.task
                    self.messages[index].source = replySource
                    self.messages[index].applicationNotice = reply.applicationNotice
                } else {
                    self.messages.append(.init(id: replyID, role: .assistant, text: reply.text, task: reply.task, source: replySource, applicationNotice: reply.applicationNotice))
                }
                if reply.applicationNotice {
                    self.failedRequest = request; self.failedFiles = selectedFiles
                    self.failedUserID = userID; self.failedNoticeID = replyID; self.canRetryReply = true
                    self.notice = "AI 已响应，但方案校验未通过；文件未处理，原消息和附件已保留。"
                }
                if let plan = reply.task {
                    if plan.liveCall != nil { self.toolFiles[plan.id] = selectedFiles }
                    self.pendingAttachments.removeValue(forKey: self.conversationID)
                }
                self.activity = .idle; self.work = nil; self.activeReplyID = nil; self.generatingText = false
                RitoRequestTrace.event(reply.applicationNotice ? "reply_application_notice" : "reply_completed",flush:true)
                self.saveConversation()
            } catch {
                guard let self, self.operationID == token else { return }
                RitoRequestTrace.failure(error)
                // Tool-planning deltas contain a status announcement, never a completed answer.
                if !request.attachments.isEmpty, replySource != .mock { self.messages.removeAll { $0.id == replyID } }
                self.activity = .idle; self.work = nil; self.activeReplyID = nil; self.generatingText = false
                if self.messages.contains(where: { $0.id == replyID }) { self.showFeedback(.error, messageID: replyID) }
                // Retry only before any reply arrives: preserve files and user-message identity.
                if !(error is CancellationError), !self.messages.contains(where: { $0.id == replyID }) {
                    self.failedRequest = request; self.failedFiles = selectedFiles; self.failedUserID = userID; self.canRetryReply = true
                }
                if !(error is CancellationError), let i = self.messages.firstIndex(where: { $0.id == userID }) {
                    let partial = self.messages.contains(where: { $0.id == replyID })
                    let prefix = error is RitoToolError || error is ToolExecutionError
                        ? "AI 方案未通过校验。" : (partial ? "AI 回复未完成，已保留部分文字。" : "本次未获得完整回答。")
                    self.messages[i].replyIssue = prefix + error.localizedDescription
                }
                self.notice = self.canRetryReply ? "这次回复未完成，原消息和附件已保留，可点击重试。" : "回复未完成，详情见对应消息。"
                self.saveConversation()

            }
        }
    }

    func confirm(_ id: UUID) {
        guard !isBusy, let index = taskIndex(id), let plan = messages[index].task,
              plan.state == .awaitingConfirmation else { return }
        if let call = plan.liveCall { confirmLive(plan, call: call); return }
        messages[index].task?.state = .running
        clearFeedback()
        activity = .executing; notice = nil
        saveConversation()
        let token = UUID(); operationID = token
        let simulator = self.simulator
        work = Task { [weak self] in
            do {
                let results = try await simulator.simulate(plan) { [weak self] value in
                    guard let self, self.operationID == token, let i = self.taskIndex(id) else { return }
                    self.messages[i].task?.progress = max(0, min(1, value))
                }
                try Task.checkCancellation()
                guard let self, self.operationID == token, let i = self.taskIndex(id) else { return }
                self.messages[i].task?.state = .completed
                self.messages[i].task?.progress = 1
                self.messages[i].task?.results = results
                self.showFeedback(.success, messageID: self.messages[i].id)
                self.activity = .idle; self.work = nil
                self.saveConversation()
            } catch {
                guard let self, self.operationID == token, let i = self.taskIndex(id) else { return }
                self.messages[i].task?.state = .failed
                self.messages[i].task?.error = "模拟执行失败：\(error.localizedDescription)"
                self.showFeedback(.error, messageID: self.messages[i].id)
                self.activity = .idle; self.work = nil
                self.saveConversation()
            }
        }
    }

    func dismiss(_ id: UUID) {
        guard let index = taskIndex(id) else { return }
        if messages[index].task?.state == .running { stop(); return }
        guard messages[index].task?.state == .awaitingConfirmation else { return }
        messages[index].task?.state = .cancelled
        localPasswords.removeValue(forKey:id); taskLocalOptions.removeValue(forKey:id); preparedTools.removeValue(forKey:id)
        saveConversation()
    }

    func stop() {
        canRetryReply = false; failedRequest = nil; failedFiles = [:]; failedUserID = nil; failedNoticeID = nil
        guard isBusy else { return }
        let executingFiles = activity == .executing && messages.contains { $0.task?.liveCall != nil && $0.task?.state == .running }
        work?.cancel(); work = nil; operationID = UUID()
        localPasswords.removeAll(); taskLocalOptions.removeAll(); preparedTools.removeAll()
        for index in messages.indices where messages[index].task?.state == .running {
            messages[index].task?.state = .cancelled
        }
        activity = .idle; currentToolID = nil; activeReplyID = nil; generatingText = false; clearFeedback()
        notice = serviceSource == .mock ? "模拟已停止，未对文件执行任何操作。" : serviceSource == .local ? "已停止生成，收到的文字已保留。" : "已停止生成，收到的文字已保留。云端供应商可能对已生成内容计费。"
        if executingFiles { notice = "本机任务已请求停止；已完成的文件会保留，复制整理可在文件整理记录中撤销。" }
        saveConversation()
    }

    func newConversation() {
        guard !isChoosingFiles else { return }
        stop(); preparedTools.removeAll(); localPasswords.removeAll(); taskLocalOptions.removeAll(); clearFeedback(); saveConversation(); conversationID = UUID(); messages = []; draft = ""; attachments = []; attachmentURLs = []; attachmentPaths = [:]
        selectedIntent = nil; notice = nil; operationID = UUID()
    }

    func openConversation(_ id: UUID) {
        guard !isChoosingFiles, id != conversationID,
              conversations.contains(where: { $0.id == id }) else { return }
        stop(); preparedTools.removeAll(); localPasswords.removeAll(); taskLocalOptions.removeAll(); clearFeedback(); saveConversation()
        guard let selected = conversations.first(where: { $0.id == id }) else { return }
        conversationID = id; messages = selected.messages
        draft = ""; attachments = []; attachmentURLs = []; attachmentPaths = [:]
        selectedIntent = nil; notice = nil; operationID = UUID()
    }

    func deleteConversation(_ id: UUID) {
        guard !isChoosingFiles else { return }
        pendingAttachments.removeValue(forKey: id)
        if id == conversationID {
            stop(); preparedTools.removeAll(); localPasswords.removeAll(); taskLocalOptions.removeAll(); clearFeedback(); messages = []; draft = ""; attachments = []; attachmentURLs = []; attachmentPaths = [:]
            selectedIntent = nil; notice = nil; conversationID = UUID(); operationID = UUID()
        }
        conversations.removeAll { $0.id == id }
        historyStore?.save(conversations)
    }

    func renameConversation(_ id: UUID, title: String) {
        let value = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !value.isEmpty, let i = conversations.firstIndex(where: { $0.id == id }),
              conversations[i].title != value else { return }
        var record = conversations[i]
        record.customTitle = value
        if id == conversationID { record.messages = messages }
        record.updatedAt = Date()
        persistModifiedConversation(record)
    }

    func retry(_ id: UUID) {
        guard !isBusy, let i = taskIndex(id), let state = messages[i].task?.state,
              state == .failed || state == .cancelled else { return }
        clearFeedback()
        preparedTools.removeValue(forKey: id)
        messages[i].task?.previewReady = false
        messages[i].task?.previewSummary = nil
        messages[i].task?.state = .awaitingConfirmation
        messages[i].task?.progress = 0; messages[i].task?.results = []; messages[i].task?.error = nil
        saveConversation()
    }

    func mascotState(for message: RToolAIMessage) -> RitoAnimationState {
        guard message.role == .assistant else { return .idle }
        if activeReplyID == message.id && generatingText { return .speaking }
        if message.task?.state == .running { return .working }
        if currentToolID == message.task?.id, activity == .executing { return .thinking }
        if feedbackMessageID == message.id { return feedbackState }
        return .idle
    }

    private func showFeedback(_ state: RitoAnimationState, messageID: UUID) {
        clearFeedback()
        feedbackMessageID = messageID; feedbackState = state
        feedbackWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            self.feedbackMessageID = nil; self.feedbackState = .idle; self.feedbackWork = nil
        }
    }

    private func clearFeedback() {
        feedbackWork?.cancel(); feedbackWork = nil
        feedbackMessageID = nil; feedbackState = .idle
    }

    private func saveConversation() {
        guard !messages.isEmpty else { return }
        let existing = conversations.first(where: { $0.id == conversationID })
        // Navigation and repeated saves are read-only unless the persisted content changed.
        // Keep both the existing timestamp and sidebar position when nothing changed.
        guard existing?.messages != messages else { return }
        let record = RitoAIConversation(id: conversationID, messages: messages,
            updatedAt: Date(), customTitle: existing?.customTitle)
        persistModifiedConversation(record)
    }

    private func persistModifiedConversation(_ record: RitoAIConversation) {
        conversations.removeAll { $0.id == record.id }
        conversations.insert(record, at: 0)
        conversations = Array(conversations.prefix(30))
        let retainedIDs = Set(conversations.map(\.id)).union([conversationID])
        pendingAttachments = pendingAttachments.filter { retainedIDs.contains($0.key) }
        historyStore?.save(conversations)
    }

    @ObservationIgnored private var taskLocalOptions: [UUID: RitoLocalToolOptions] = [:]
    func localOptions(for id: UUID) -> RitoLocalToolOptions { taskLocalOptions[id] ?? .init() }
    func localPassword(for id: UUID) -> String { localPasswords[id] ?? "" }

    @ObservationIgnored private var localPasswords: [UUID: String] = [:]
    func originalURL(for task: RToolAITaskPlan) -> URL? {
        task.liveCall?.attachmentIDs.first.flatMap { toolFiles[task.id]?[$0] }
    }
    func chooseTool(_ operation: RitoToolCall.Operation) {
        guard !isBusy else { return }
        selectedIntent = nil
        draft = "请使用“" + ToolRegistry.lookup(operation).name + "”处理我选择的附件，先给我确认参数和执行方案。"
        notice = nil
    }
    func updateTool(_ id: UUID, parameters: [String:String], following: [RitoToolStage], regionConfirmed: Bool, password: String, order: [UUID], localOptions: RitoLocalToolOptions) throws {
        guard !isBusy, let i = taskIndex(id), var call = messages[i].task?.liveCall,
              messages[i].task?.state != .running && messages[i].task?.state != .completed else { return }
        guard order.count == call.attachmentIDs.count, Set(order).count == order.count,
              Set(order) == Set(call.attachmentIDs) else { throw RitoToolError.invalidPlan }
        let names = Dictionary(uniqueKeysWithValues: zip(call.attachmentIDs, messages[i].task?.sourceNames ?? []))
        do {
            let values = try ToolRegistry.lookup(call.operation).values(parameters, allowMissing: true)
            call.attachmentIDs = order
            call.parameters = values; call.following = following.isEmpty ? nil : following
            call.regionConfirmed = regionConfirmed ? true : nil
            try TaskEngine.validateChain(call)
            messages[i].task?.liveCall = call
            messages[i].task?.sourceNames = order.compactMap { names[$0] }
            messages[i].task?.state = .awaitingConfirmation; messages[i].task?.error = nil
            messages[i].task?.previewReady = false; messages[i].task?.previewSummary = nil
            messages[i].task?.taskPreviewData = nil; messages[i].task?.outputLocation = nil
            preparedTools.removeValue(forKey:id)
            if call.operation == .pdf_encrypt { localPasswords[id] = password }
            taskLocalOptions[id] = localOptions
            notice = nil
            saveConversation()
        } catch { throw error }
    }
    func undoRename(_ id: UUID) {
        guard !isBusy, let i = taskIndex(id) else { return }
        let moves = messages[i].task?.results.compactMap(\.renameRecovery) ?? []
        guard !moves.isEmpty else { return }
        activity = .executing; currentToolID = id; let token = UUID(); operationID = token
        work = Task { [weak self] in
            let child = Task.detached { await TaskEngine.undoRename(moves) }
            let result = await withTaskCancellationHandler { await child.value } onCancel: { child.cancel() }
            guard let self, self.operationID == token, let i = self.taskIndex(id) else { return }
            switch result {
            case .success:
                self.messages[i].task?.results = moves.map { .init(sourceName:$0.original.lastPathComponent,detail:"已恢复原文件名。",
                    fileReference:RitoResultFile.safeExtensions.contains($0.original.pathExtension.lowercased()) ? .capture($0.original) : nil) }
                self.showFeedback(.success,messageID:self.messages[i].id)
            case .failure(let errors): self.notice = errors.joined(separator:"\n")
            }
            self.activity = .idle; self.currentToolID = nil; self.work = nil; self.saveConversation()
        }
    }

    private func confirmLive(_ plan: RToolAITaskPlan, call: RitoToolCall) {
        guard let files = toolFiles[plan.id] else {
            notice = "此历史方案没有保留文件访问权限，请重新添加附件并生成新方案。"; return
        }
        let token = UUID(); operationID = token
        clearFeedback(); activity = .executing; currentToolID = plan.id; notice = nil
        work = Task { [weak self] in
            do {
                guard let self else { return }
                if let prepared = self.preparedTools[plan.id], plan.previewReady == true {
                    guard let i = self.taskIndex(plan.id) else { return }
                    self.messages[i].task?.state = .running
                    await RitoLocalEngine.shared.unload()
                    let child = Task.detached {
                        try await ToolRegistry.lookup(prepared.call.operation).execute(prepared) { [weak self] value in
                            guard let self, self.operationID == token, let i = self.taskIndex(plan.id), self.messages[i].task?.state == .running else { return }
                            // Finish the read before opening the mutable optional-chain access.
                            // Reading messages on that assignment's RHS traps Swift exclusivity.
                            guard value.isFinite else { return }
                            let previous = self.messages[i].task?.progress ?? 0
                            let next = max(previous, max(0, min(1, value)))
                            self.messages[i].task?.progress = next
                        }
                    }
                    let results = try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
                    try Task.checkCancellation()
                    guard self.operationID == token, let i = self.taskIndex(plan.id) else { return }
                    self.messages[i].task?.results = results
                    self.messages[i].task?.progress = 1; self.messages[i].task?.state = .completed
                    self.preparedTools.removeValue(forKey: plan.id); self.localPasswords.removeValue(forKey: plan.id); self.taskLocalOptions.removeValue(forKey: plan.id)
                    self.showFeedback(.success, messageID: self.messages[i].id)
                } else {
                    var destination: URL?
                    if ![.ocr, .pdf_ocr, .file_rename].contains(call.operation) {
                        guard let folder = await self.destinationPicker() else {
                            if self.operationID == token { self.activity = .idle; self.currentToolID = nil; self.work = nil }; return
                        }
                        try Task.checkCancellation()
                        let suffix = String(UUID().uuidString.prefix(8))
                        destination = folder.appendingPathComponent(call.operation == .pdf_merge && (call.following ?? []).isEmpty ? "Rito合并_" + suffix + ".pdf" : [.organize_copy,.organize_move].contains(call.operation) ? "Rito整理结果_" + suffix : call.operation == .collage ? "Rito拼图_" + suffix : "Rito任务_" + suffix)
                    }
                    let output = destination
                    let options = self.localOptions(for: plan.id)
                    let password = self.localPasswords[plan.id]
                    let child = Task.detached { try await TaskEngine.prepare(call, files: files, destination: output, password: password, localOptions: options) }
                    let prepared = try await withTaskCancellationHandler { try await child.value } onCancel: { child.cancel() }
                    try Task.checkCancellation()
                    guard self.operationID == token, let i = self.taskIndex(plan.id) else { return }
                    self.preparedTools[plan.id] = prepared
                    self.messages[i].task?.previewReady = true
                    self.messages[i].task?.previewSummary = prepared.summary
                    self.messages[i].task?.outputLocation = prepared.destination
                    self.messages[i].task?.taskPreviewData = prepared.previewData
                    self.notice = "执行预览已就绪。请核对文件、顺序与结果位置，再点击确认本机执行。"
                }
                guard self.operationID == token else { return }
                self.activity = .idle; self.currentToolID = nil; self.work = nil; self.saveConversation()
            } catch {
                guard let self, self.operationID == token, let i = self.taskIndex(plan.id) else { return }
                self.messages[i].task?.state = .failed
                if let partial = error as? ToolExecutionFailure {
                    self.messages[i].task?.results = partial.results
                    if partial.cancelled { self.messages[i].task?.state = .cancelled }
                }
                self.preparedTools.removeValue(forKey: plan.id); self.localPasswords.removeValue(forKey: plan.id); self.taskLocalOptions.removeValue(forKey: plan.id)
                self.messages[i].task?.error = "本机处理未完成：" + error.localizedDescription + "。部分完成时请检查结果与整理记录。"
                self.activity = .idle; self.currentToolID = nil; self.work = nil
                self.showFeedback(.error, messageID: self.messages[i].id); self.saveConversation()
            }
        }
    }

    static func chooseDestination() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "选择结果保存位置"
        panel.message = "现在只生成执行预览，确认后才处理文件；原文件保留。"
        return await FileDialogs.response(to: panel) == .OK ? panel.url : nil
    }

    func outputPath(for id: UUID) -> String? { messages.first { $0.task?.id == id }?.task?.outputLocation?.path ?? preparedTools[id]?.destination?.path }
    private func taskIndex(_ id: UUID) -> Int? { messages.firstIndex { $0.task?.id == id } }
}
