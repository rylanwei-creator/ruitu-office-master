#if os(macOS)
import SwiftUI

struct RToolAIView: View {
    @Bindable var model: RToolAIViewModel
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var composerFocused = false
    @State private var editorHeight: CGFloat = 44
    @State private var showingSettings = false
    @State private var showingTools = false
    @State private var editingPlan: RToolAITaskPlan?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.messages.isEmpty { welcome } else { conversation }
            composer
        }.background(RToolAIStyle.background).foregroundStyle(AppColors.textPrimary)
            .sheet(isPresented: $showingSettings) {
                VStack { RitoAISettingsView(); Button("完成") { showingSettings = false }.padding(.bottom, 16) }
                    .frame(width: 700, height: 540)
            }
            .sheet(isPresented:$showingTools) { RitoAllToolsView(attachments:model.attachments.isEmpty ? model.continuingAttachments : model.attachments,choose:model.chooseTool) }
            .sheet(item:$editingPlan) { plan in
                RitoToolParameterEditor(plan:plan,originalURL:model.originalURL(for:plan), password:model.localPassword(for:plan.id),
                                        localOptions:model.localOptions(for:plan.id)) { parameters,following,region,password,order,options in
                    try model.updateTool(plan.id,parameters:parameters,following:following,regionConfirmed:region,password:password,order:order,localOptions:options)
                }
            }
            .onChange(of: isVisible) { _, visible in if !visible { composerFocused = false } }
            .onChange(of: model.conversationID) { _, _ in
                if isVisible && model.messages.isEmpty { composerFocused = true }
            }
    }
    private var header: some View {
        HStack(spacing: 9) {
            RToolAIAvatar(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rito AI").font(.system(size: 17, weight: .semibold))
                Text("你的 AI 办公小伙伴").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(model.serviceTitle).font(.system(size: 10, weight: .medium)).foregroundStyle(RToolAIStyle.accent)
                .padding(.horizontal, 7).padding(.vertical, 4).background(RToolAIStyle.accent.opacity(0.08), in: Capsule())
            Spacer(minLength: 4)
            Button("全部工具") { showingTools = true }.controlSize(.small).disabled(model.isBusy)
            Button("AI 设置") { showingSettings = true }.controlSize(.small).disabled(model.isBusy)
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }
    private var welcome: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 14) {
                    RitoMascotView(size: 140, state: .idle, isAnimating: isVisible, respondsToHover: true)
                    HStack(spacing: 0) { Text("你好，我是 "); Text("Rito").foregroundStyle(RToolAIStyle.gradient); Text("！") }
                        .font(.system(size: 28, weight: .semibold))
                    Text("你的 AI 办公小伙伴，让繁琐的工作变简单。")
                        .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: geometry.size.width >= 780 ? 4 : 2), spacing: 10) {
                        ForEach([RToolAIIntent.organize, .pdfDocument, .extractText, .summarize]) { intent in
                            RToolAIQuickCommand(intent: intent) { model.choose(intent); composerFocused = true }
                        }
                    }.padding(.top, 16)
                    Button("查看全部工具") { showingTools = true }.buttonStyle(.borderless)
                    Text("选择入口仅填写指令；首次使用本地模式请先在 AI 设置下载模型。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(24).frame(maxWidth: 820)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
            }
        }
    }
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(model.messages) { message in
                        let state = model.mascotState(for: message)
                        RToolAIMessageRow(message: message, canConfirm: !model.isBusy,
                                          confirm: model.confirm, cancel: model.dismiss, retry: model.retry,
                                          outputPath: message.task.flatMap { model.outputPath(for: $0.id) },
                                          chooseAttachmentPreview: { id in Task { await model.choosePreview(attachmentID: id) } },
                                          chooseResultPreview: { task, result in Task { await model.choosePreview(taskID: task, resultID: result) } },
                                          chooseResultFile: { task, result in Task { await model.chooseResultFile(taskID: task, resultID: result) } }, editParameters: { id in editingPlan = model.messages.first { $0.task?.id == id }?.task }, undoRename: model.undoRename, mascotState: state, isAnimating: isVisible && state != .idle)
                            .id(message.id)
                    }
                    if model.activity == .replying && !model.generatingText {
                        HStack(spacing: 10) {
                            RToolAIAvatar(size: 40, state: .thinking, isAnimating: isVisible)
                            ProgressView().controlSize(.small)
                            Text("已注册办公工具通过本机执行；先核对参数、预览和文件授权。").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(model.replyStatus).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Color.clear.frame(height: 1).id("conversation-bottom")
                }.padding(20).frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .onChange(of: model.messages.count) { _, _ in scroll(proxy) }
            .onChange(of: model.messages.last?.text) { _, _ in scroll(proxy) }
            .onChange(of: model.conversationID) { _, _ in scroll(proxy) }
            .onChange(of: model.activity) { _, _ in scroll(proxy) }
            .onChange(of: model.messages.last?.task?.state) { _, _ in scroll(proxy) }
            .onChange(of: isVisible) { _, visible in if visible { scroll(proxy) } }
            .onAppear { scroll(proxy) }
        }
    }
    private var composer: some View {
        VStack(spacing: 6) {
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 10) {
                    Text(notice).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    if model.canRetryReply {
                        Button("重试回复", action: model.retryReply).disabled(model.isBusy)
                        Button("AI 设置") { showingSettings = true }.disabled(model.isBusy)
                    }
                }.controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 8) {
                if !model.attachments.isEmpty {
                    ScrollView(.horizontal) { HStack(spacing: 6) { ForEach(model.attachments) { attachment in
                        RToolAIAttachmentChip(attachment: attachment) { model.removeAttachment(attachment.id) }.disabled(model.isBusy)
                    } } }.scrollIndicators(.hidden)
                } else if !model.continuingAttachments.isEmpty {
                    HStack(spacing: 8) {
                        Label("沿用附件：" + model.continuingAttachments.map(\.name).joined(separator: "、"), systemImage: "paperclip")
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button("不再沿用", action: model.clearContinuingAttachments)
                            .buttonStyle(.borderless).disabled(model.isBusy)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                RitoComposerEditor(text: $model.draft, isFocused: $composerFocused, measuredHeight: $editorHeight, isEnabled: !model.isBusy) {
                    if isVisible && model.canSend { model.send() }
                }.frame(height: editorHeight)
                HStack(spacing: 12) {
                    Button { Task { await model.chooseFiles() } } label: { Label("添加附件", systemImage: "paperclip") }
                        .buttonStyle(.borderless).disabled(model.isBusy || model.isChoosingFiles)
                    Menu { ForEach(RToolAIIntent.allCases) { intent in Button(intent.title) { model.choose(intent); composerFocused = true } } }
                    label: { Label("常用任务", systemImage: "square.grid.2x2") }.menuStyle(.borderlessButton).fixedSize().disabled(model.isBusy)
                    Spacer(minLength: 0)
                    if model.isBusy { Button(model.activity == .executing ? "停止任务" : model.serviceSource == .mock ? "停止演示" : "停止生成", action: model.stop).buttonStyle(.bordered).keyboardShortcut(".", modifiers: .command).help("停止当前回复或任务（⌘.）") }
                    else {
                        Text("↵ 发送 · ⇧↵ 换行").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Button(action: model.send) { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20) }
                            .buttonStyle(.borderedProminent).tint(RToolAIStyle.accent).disabled(!model.canSend || !isVisible)
                            .keyboardShortcut(.return, modifiers: .command).accessibilityLabel("发送消息")
                    }
                }.font(.system(size: 11)).controlSize(.small)
            }.padding(12).background(RToolAIStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(composerFocused ? RToolAIStyle.accent.opacity(0.5) : RToolAIStyle.border))
            Text("已注册办公工具通过本机执行；先核对参数、预览和文件授权。").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(model.serviceSource == .local ? "本地 AI · 文字留在本机 · 附件需确认工具计划后处理" : "自定义云端 · 仅发送文字与有限上下文 · 附件内容与文件名不上传")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 12).frame(maxWidth: 820).frame(maxWidth: .infinity)
    }
    private func scroll(_ proxy: ScrollViewProxy) {
        guard isVisible else { return }
        proxy.scrollTo("conversation-bottom", anchor: .bottom)
    }
}
#endif
