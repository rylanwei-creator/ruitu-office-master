#if os(macOS)
import SwiftUI
import AppKit

enum RToolAIStyle {
    static var accent: Color { AppColors.primary }
    static let gradient = LinearGradient(colors: [Color(light: "0CABA9", dark: "58D8C9"), Color(light: "6354C7", dark: "B0A4FF")], startPoint: .leading, endPoint: .trailing)
    static var surface: Color { AppColors.cardBackground }
    static var background: Color { AppColors.background }
    static var border: Color { AppColors.textPrimary.opacity(0.08) }
    @MainActor static let mascot = NSImage(contentsOf: AppResources.bundle.url(forResource: "RitoMascot", withExtension: "png") ?? URL(fileURLWithPath: "/nonexistent"))
}

struct RToolAIAvatar: View {
    var size: CGFloat = 40
    var state: RitoAnimationState = .idle
    var isAnimating = false
    var body: some View {
        RitoMascotView(size: size, state: state, isAnimating: isAnimating).accessibilityHidden(true)
    }
}

/// Both destinations are available on every page; the highlighted segment moves left/right.
struct RitoModeSwitch: View {
    @Binding var showingAI: Bool
    @Namespace private var selection
    var body: some View {
        HStack(spacing: 2) {
            segment("工具", symbol: "square.grid.2x2", ai: false)
            segment("Rito AI", symbol: "sparkles", ai: true)
        }.padding(3).background(Color.primary.opacity(0.055), in: Capsule())
            .accessibilityElement(children: .contain).accessibilityLabel("办公模式切换")
    }
    private func segment(_ title: String, symbol: String, ai: Bool) -> some View {
        Button { withAnimation(.easeInOut(duration: 0.18)) { showingAI = ai } } label: {
            Label(title, systemImage: symbol).labelStyle(.titleAndIcon).font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .foregroundStyle(showingAI == ai ? (ai ? RToolAIStyle.accent : Color.primary) : Color.secondary)
                .background {
                    if showingAI == ai { Capsule().fill(RToolAIStyle.surface).shadow(color: .black.opacity(0.06), radius: 2, y: 1).matchedGeometryEffect(id: "mode", in: selection) }
                }.contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityLabel(ai ? "切换到 Rito AI" : "切换到工具")
            .accessibilityAddTraits(showingAI == ai ? .isSelected : [])
    }
}

struct RToolAIQuickCommand: View {
    let intent: RToolAIIntent
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: intent.symbol).font(.system(size: 18)).foregroundStyle(RToolAIStyle.accent)
                    .frame(width: 34, height: 34).background(RToolAIStyle.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(intent.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                    Text(intent.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }.padding(12).frame(height: 76).background(RToolAIStyle.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RToolAIStyle.border)).contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel("快捷指令：\(intent.title)")
    }
}

struct RToolAIAttachmentChip: View {
    let attachment: RToolAIAttachment
    var remove: (() -> Void)?
    var choosePreview: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 7) {
            if let data = attachment.previewData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 42, height: 48)
                    .accessibilityLabel("图片预览：\(attachment.name)")
            } else { Image(systemName: attachment.isDirectory == true ? "folder" : RitoImagePreview.isImage(attachment.name) ? "photo" : "doc").foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name).lineLimit(1).truncationMode(.middle).font(.system(size: 11, weight: .medium))
                Text(attachment.isDirectory == true ? "文件夹" : ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file)).font(.system(size: 10)).foregroundStyle(.secondary)
                if attachment.previewData == nil, RitoImagePreview.isImage(attachment.name), let choosePreview {
                    Button("补充图片预览", action: choosePreview).buttonStyle(.borderless).font(.caption2)
                }
            }
            if let remove { Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("移除附件 \(attachment.name)") }
        }.padding(8).frame(maxWidth: 220, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8)).help(attachment.name)
    }
}

struct RToolAITaskCard: View {
    let plan: RToolAITaskPlan
    let canConfirm: Bool
    let confirm: () -> Void
    let cancel: () -> Void
    let retry: () -> Void
    var outputPath: String? = nil
    var chooseResultPreview: ((UUID) -> Void)? = nil
    var chooseResultFile: ((UUID) -> Void)? = nil
    var editParameters: (() -> Void)? = nil
    var undoRename: (() -> Void)? = nil
    @State private var confirmingUndoRename = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                Label(plan.title, systemImage: plan.intent.symbol).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Text((plan.liveCall == nil ? "演示模式 · " : "本机执行 · ") + status).font(.system(size: 10)).foregroundStyle(RToolAIStyle.accent)
            }
            if let call = plan.liveCall {
                Text("工具：" + ([call.operation] + (call.following ?? []).map(\.operation)).map { ToolRegistry.lookup($0).name }.joined(separator:" → ")).font(.caption)
                Text("风险：" + ToolRegistry.lookup(call.operation).risk.rawValue + " · 默认不覆盖原文件").font(.caption2).foregroundStyle(.secondary)
                if plan.previewReady != true {
                    let parameters = ToolRegistry.lookup(call.operation).parameterSummary(call.parameters ?? [:]) + (call.following ?? []).flatMap { stage in
                        [ToolRegistry.lookup(stage.operation).name + "："] + ToolRegistry.lookup(stage.operation).parameterSummary(stage.parameters ?? [:])
                    }
                    if !parameters.isEmpty {
                        DisclosureGroup("本次参数") {
                            Text(parameters.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.font(.caption)
                    } else if ![.pdf_merge, .pdf_encrypt].contains(call.operation) {
                        Text("此工具没有额外处理参数。").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if plan.state != .completed && plan.state != .running, let editParameters { Button("设置参数",action:editParameters).controlSize(.small).disabled(!canConfirm) }
            }
            if plan.state == .awaitingConfirmation || plan.state == .running {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 8) {
                            Image(systemName: stepSymbol(index)).foregroundStyle(stepColor(index)).frame(width: 16)
                            Text("\(index + 1). \(step)").foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }.font(.system(size: 12))
                    }
                }
                ForEach(Array(plan.sourceNames.enumerated()), id: \.offset) { _, name in
                    Label(name, systemImage: "doc").font(.system(size: 11)).lineLimit(2).textSelection(.enabled)
                }
                if plan.state == .awaitingConfirmation {
                    Text(plan.liveCall == nil ? "仅演示流程，不读取或修改文件。" : "预览后需再次确认；原文件保留，识别内容不发送给 AI。").font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Button(plan.liveCall == nil ? "确认模拟执行" : plan.previewReady == true ? "确认本机执行" : "生成执行预览", action: confirm).buttonStyle(.borderedProminent).tint(RToolAIStyle.accent).disabled(!canConfirm)
                        Button("取消此任务", action: cancel).buttonStyle(.bordered)
                    }.controlSize(.small)
                } else {
                    HStack(spacing: 10) {
                        ProgressView(value: plan.progress).tint(RToolAIStyle.accent)
                        Text("\(Int(plan.progress * 100))%").font(.caption).monospacedDigit()
                    }
                    HStack { Text(plan.liveCall == nil ? "正在演示处理流程，未实际读取文件" : "正在本机处理，已完成项会保留").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("取消任务", action: cancel).controlSize(.small) }
                }
            }
            if let rows = plan.previewSummary, plan.previewReady == true, plan.state != .completed {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in Text(row).font(.caption).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(200, CGFloat(rows.count) * 22 + 8))
            }
            if let data = plan.taskPreviewData, plan.state == .awaitingConfirmation, let image = NSImage(data:data) {
                Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:180)
                Text("本机生成的预览；请核对构图与处理参数。").font(.caption2).foregroundStyle(.secondary)
            }
            if let outputPath, !(plan.liveCall?.operation == .pdf_merge && plan.state == .completed) {
                Text("结果位置：" + outputPath).font(.caption).textSelection(.enabled)
                if plan.state == .completed {
                    Button("在 Finder 中显示结果") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outputPath)]) }.controlSize(.small)
                }
            }
            if plan.state == .completed || ([.failed,.cancelled].contains(plan.state) && !plan.results.isEmpty) {
                if let operation = plan.liveCall?.operation, [.organize_copy,.organize_move].contains(operation) {
                    RitoOrganizationSummaryView(summary: .init(results: plan.results))
                } else {
                ForEach(plan.results) { result in
                    if plan.liveCall?.operation == .pdf_merge {
                        RitoPDFResultRow(result: result, fallbackPath: outputPath,
                            associate: chooseResultFile.map { action in { action(result.id) } })
                    } else if result.fileReference != nil || result.failed == true {
                        RitoGeneratedResultRow(result:result)
                    } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            Label(result.sourceName, systemImage: "doc.text").font(.system(size: 12, weight: .medium))
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button((plan.liveCall?.operation == .ocr || plan.liveCall?.operation == .pdf_ocr) ? "复制全文" : "复制说明") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.detail, forType: .string)
                            }.controlSize(.small).accessibilityLabel((plan.liveCall?.operation == .ocr ? "复制全文：" : "复制说明：") + result.sourceName)
                        }
                        if plan.liveCall?.operation == .ocr {
                            RitoOCRResultPreview(result: result, choosePreview: chooseResultPreview.map { action in { action(result.id) } })
                        } else {
                            Text(result.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                }
                if plan.results.contains(where:{ $0.renameRecovery != nil }), undoRename != nil {
                    Button("撤销这次改名") { confirmingUndoRename = true }.controlSize(.small).disabled(!canConfirm)
                }
                Text(plan.liveCall == nil ? "示例结果 · 没有生成可下载文件" : "实际本机处理结果 · 未上传给 AI").font(.caption2).foregroundStyle(.secondary)
            }
            if plan.state == .cancelled { Text(plan.liveCall == nil ? "模拟任务已取消，文件保持原样。" : "已取消。部分完成时请检查结果；复制整理可在整理记录中撤销。").font(.caption).foregroundStyle(.secondary) }
            if let error = plan.error { Text(error).font(.caption).foregroundStyle(.red) }
            if plan.state == .failed || plan.state == .cancelled { Button(plan.liveCall == nil ? "重新准备演示方案" : "重新准备执行预览", action: retry).disabled(!canConfirm).controlSize(.small) }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RToolAIStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RToolAIStyle.border))
            .confirmationDialog("确认恢复原文件名？",isPresented:$confirmingUndoRename) {
                Button("确认恢复") { undoRename?() }
                Button("取消",role:.cancel) {}
            } message: { Text("只恢复未变化的文件，原位置已有文件时不会覆盖。") }
    }
    private func stepSymbol(_ index: Int) -> String {
        let step = Int(plan.progress * Double(plan.steps.count))
        if plan.state == .running && index < step { return "checkmark.circle.fill" }
        return plan.state == .running && index == step ? "circle.dotted" : "circle"
    }
    private func stepColor(_ index: Int) -> Color { plan.state == .running && index <= Int(plan.progress * Double(plan.steps.count)) ? RToolAIStyle.accent : .secondary }
    private var status: String {
        switch plan.state {
        case .awaitingConfirmation: "等待确认"
        case .running: plan.liveCall == nil ? "模拟处理中" : "处理中"
        case .completed: plan.liveCall == nil ? "模拟完成" : "已完成"
        case .cancelled: "已取消"
        case .failed: "未完成"
        }
    }
}

struct RToolAIMessageRow: View {
    let message: RToolAIMessage
    let canConfirm: Bool
    let confirm: (UUID) -> Void
    let cancel: (UUID) -> Void
    let retry: (UUID) -> Void
    var outputPath: String? = nil
    var chooseAttachmentPreview: ((UUID) -> Void)? = nil
    var chooseResultPreview: ((UUID, UUID) -> Void)? = nil
    var chooseResultFile: ((UUID, UUID) -> Void)? = nil
    var editParameters: ((UUID) -> Void)? = nil
    var undoRename: ((UUID) -> Void)? = nil
    var mascotState: RitoAnimationState = .idle
    var isAnimating = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .assistant { RToolAIAvatar(size: 40, state: mascotState, isAnimating: isAnimating) } else { Spacer(minLength: 42) }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(message.role == .assistant ? (message.applicationNotice == true ? "应用提示 · 未执行文件操作" : message.source == .local ? "Rito · 本地 AI" : message.source == .custom ? "Rito · 自定义 API" : "Rito · 演示历史") : "你")
                    Text(message.createdAt, style: .time)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.plain).help("复制消息").accessibilityLabel("复制消息")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                Text(message.text).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let issue = message.replyIssue {
                    Label(issue, systemImage: "exclamationmark.bubble")
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("回复状态：" + issue)
                }
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) { ForEach(message.attachments) { attachment in RToolAIAttachmentChip(attachment: attachment, choosePreview: chooseAttachmentPreview.map { action in { action(attachment.id) } }) } }
                }
                if let plan = message.task { RToolAITaskCard(plan: plan, canConfirm: canConfirm, confirm: { confirm(plan.id) }, cancel: { cancel(plan.id) }, retry: { retry(plan.id) }, outputPath: outputPath, chooseResultPreview: chooseResultPreview.map { action in { action(plan.id, $0) } }, chooseResultFile: chooseResultFile.map { action in { action(plan.id, $0) } }, editParameters: editParameters.map { action in { action(plan.id) } }, undoRename: undoRename.map { action in { action(plan.id) } }) }
            }.padding(message.role == .user ? 11 : 0)
                .frame(maxWidth: message.role == .user ? 500 : 732, alignment: .leading)
                .background(message.role == .user ? RToolAIStyle.accent.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            if message.role == .assistant { Spacer(minLength: 0) }
        }.frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }
}
/// The text owns a bounded scroll region; it is never shortened for display or copy.
struct RitoOCRResultPreview: View {
    let result: RToolAIResult
    var choosePreview: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let data = result.previewData, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity).frame(height: 150)
                    .background(RToolAIStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("OCR 原图预览：\(result.sourceName)")
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                    Text("这条旧记录未保存图片预览").font(.caption).foregroundStyle(.secondary)
                    if let choosePreview { Button("补充图片预览", action: choosePreview).controlSize(.small) }
                }
            }
            HStack {
                Text("识别文字").font(.caption.bold())
                Spacer()
                Text("\(result.detail.count) 字符 · 可滚动阅读").font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView(.vertical) {
                Text(result.detail).font(.system(size: 12)).lineSpacing(3)
                    .foregroundStyle(AppColors.textPrimary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(10)
            }.scrollIndicators(.visible)
                .frame(height: result.detail.count > 180 ? 220 : 100)
                .background(RToolAIStyle.surface, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("完整 OCR 文字：\(result.sourceName)")
        }
    }
}
#endif
