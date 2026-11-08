import SwiftUI
import AppKit

struct RitoAllToolsView: View {
    let attachments: [RToolAIAttachment]
    let choose: (RitoToolCall.Operation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var recommendedOnly = false
    @State private var showingHistory = false
    @State private var records: [NativeToolTaskRecord] = []
    private var tools: [RegisteredTool] {
        ToolRegistry.search(search).filter { tool in !recommendedOnly || attachments.allSatisfy(tool.accepts) }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { Text("全部办公工具").font(.title2.bold()); Spacer(); Button("完成") { dismiss() } }
            Text("选择工具只填写指令；添加附件、生成预览并确认后才处理。").font(.caption).foregroundStyle(.secondary)
            Toggle("查看工具执行记录",isOn:$showingHistory)
            if showingHistory { history } else { selection }
        }.padding(20).frame(width:660,height:600)
            .task { records = await Task.detached { NativeToolTaskJournal.load() }.value }
    }
    private var selection: some View {
        VStack(alignment:.leading,spacing:10) {
            TextField("搜索工具名称或用途",text:$search).textFieldStyle(.roundedBorder)
            if !attachments.isEmpty { Toggle("仅显示适用于当前附件的工具",isOn:$recommendedOnly) }
            ScrollView {
                LazyVStack(spacing:8) { ForEach(tools) { tool in toolRow(tool) } }
            }
        }
    }
    private func toolRow(_ tool: RegisteredTool) -> some View {
        Button { choose(tool.operation); dismiss() } label: {
            HStack(spacing:10) {
                Image(systemName:tool.symbol).frame(width:26).foregroundStyle(RToolAIStyle.accent)
                VStack(alignment:.leading,spacing:3) {
                    Text(tool.name).font(.headline)
                    Text(tool.description).font(.caption).foregroundStyle(.secondary)
                    Text(tool.risk.rawValue + " · 执行前确认").font(.caption2)
                        .foregroundStyle(tool.risk == .changesOriginals ? Color.orange : Color.secondary)
                }
                Spacer()
                Image(systemName:"chevron.right").foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                .background(RToolAIStyle.surface,in:RoundedRectangle(cornerRadius:10))
        }.buttonStyle(.plain)
    }
    private var history: some View {
        ScrollView {
            LazyVStack(alignment:.leading,spacing:10) {
                ForEach(records) { record in historyRow(record) }
                if records.isEmpty { Text("暂无工具执行记录").foregroundStyle(.secondary) }
            }
        }
    }
    private func historyRow(_ record: NativeToolTaskRecord) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text((RitoToolCall.Operation(rawValue:record.tool).map { ToolRegistry.lookup($0).name } ?? "办公任务") + " · " + status(record.state)).font(.headline)
            Text(record.date,style:.date).font(.caption)
            Text("已记录结果：\(record.results.count)").font(.caption)
            if let output = record.output {
                Button("在Finder中显示输出") {
                    guard output.isFileURL, (try? FileOrganizerService.noLinks(output)) != nil else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                }.controlSize(.small)
            }
            if record.state != "completed" {
                Text("中断或失败后可能已有输出文件，请核对输出目录；不会自动重跑。").font(.caption).foregroundStyle(.orange)
            }
            if record.state == "interrupted" {
                Text("上次任务中断；不会自动重跑。请检查已生成文件，再重新准备方案。").font(.caption).foregroundStyle(.orange)
            }
        }.padding(10)
    }
    private func status(_ raw: String) -> String {
        switch raw { case "completed": "已完成"; case "failed": "未完成"; case "cancelled": "已停止"; case "interrupted": "已中断"; default: "处理中" }
    }
}
struct RitoGeneratedResultRow: View {
    let result: RToolAIResult
    @State private var error: String?
    @State private var copied = false
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack {
                Label(result.sourceName,systemImage:result.failed == true ? "exclamationmark.triangle" : "doc")
                    .font(.system(size:12,weight:.semibold)).textSelection(.enabled)
                    .onTapGesture(count:2) { perform { try RitoResultFileActions.open($0) } }
                Spacer()
                if result.fileReference != nil {
                    Button("复制文件") { perform { try RitoResultFileActions.copy($0); copied = true } }.controlSize(.small)
                }
            }
            if let data = result.previewData, let image = NSImage(data:data) {
                Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:140)
            }
            Text(result.detail).font(.caption).foregroundStyle(result.failed == true ? .red : .secondary).textSelection(.enabled)
            if result.fileReference != nil {
                HStack { Button("打开文件") { perform { try RitoResultFileActions.open($0) } }; Button("在Finder中显示") { perform { try RitoResultFileActions.reveal($0) } } }.controlSize(.small)
            }
            if copied { Text("文件已复制，可在Finder粘贴。").font(.caption2) }
        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
            .background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
            .alert("结果文件不可用",isPresented:Binding(get:{ error != nil },set:{ if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
    private func perform(_ action: (RitoResultFile) throws -> Void) {
        do { guard let file = result.fileReference else { return }; try action(file) }
        catch { self.error = error.localizedDescription }
    }
}
