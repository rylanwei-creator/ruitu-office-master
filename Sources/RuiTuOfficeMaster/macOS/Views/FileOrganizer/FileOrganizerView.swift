import SwiftUI
import AppKit

struct FileOrganizerView: View {
    @State private var model = FileOrganizerViewModel()
    @State private var dropTargeted = false
    @State private var confirmMove = false
    @State private var confirmUndo = false
    @State private var confirmDeleteRecord = false
    @State private var recordToDelete: OrganizerJournal?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageHeader(title: "文件整理", subtitle: "按文件类型归类 · 先预览路径再执行 · 本机记录与撤销")
                sourceSection
                settingsSection
                HStack(spacing: 14) {
                    Button("生成整理预览") { model.preview() }.buttonStyle(.borderedProminent).disabled(model.busy || model.roots.isEmpty || model.destination == nil)
                    if model.busy {
                        ProgressView().controlSize(.small)
                        Text(model.isDeletingRecord ? "正在删除记录…" : model.isScanning ? "扫描中：\(model.scanned) 个项目" : (model.isUndoing ? "撤销中" : "整理中：\(model.completed) 项") + (model.currentName.isEmpty ? "" : " · \(model.currentName)"))
                        if !model.isDeletingRecord { Button("停止") { model.cancel() } }
                    }
                }
                if let plan = model.plan { previewSection(plan) }
                CleanupMessages(error: model.errorMessage, status: model.statusMessage)
                if let journal = model.journal { resultSection(journal) }
                else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("整理记录与结果").font(.title3.bold())
                        Text("暂无整理记录").foregroundStyle(AppColors.textSecondary)
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 14))
                }
                Text("按扩展名分为图片、文档、视频、音频、压缩包、代码和其他。默认复制会额外占用存储空间；移动会改变文件路径。停止会保留已完成项，单个文件复制期间可能需要等待。撤销只操作内容与身份校验一致的文件，不覆盖原位置已有文件；空文件夹保留。")
                    .font(.callout).foregroundStyle(AppColors.textSecondary)
                PrivacyNoticeView()
            }.padding(32).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }.background(AppColors.background)
        .task { await model.loadRecords() }
        .onChange(of: model.configuration) { _, _ in model.invalidate() }
        .alert("确认移动这些文件？", isPresented: $confirmMove) {
            Button("取消", role: .cancel) {}
            Button("按预览移动") { model.execute() }
        } message: { Text("移动将改变原文件路径，可能影响其他软件的引用。请核对预览中的去向；无法完成的项目会显示原因。") }
        .alert("撤销这次整理？", isPresented: $confirmUndo) {
            Button("取消", role: .cancel) {}
            Button("核对文件并撤销") { model.undo() }
        } message: { Text("复制模式移除本次生成且未变化的副本；移动模式恢复原路径。文件已变化或原位置被占用时会保留文件并说明原因。") }
        .alert("删除这条整理记录？", isPresented: $confirmDeleteRecord, presenting: recordToDelete) { record in
            Button("取消", role: .cancel) {}
            Button("删除记录", role: .destructive) { Task { await model.deleteRecord(record.id) } }
        } message: { record in
            Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.configuration.mode.rawValue) · \(record.items.count) 个文件\n\n仅删除这条记录，原文件和整理后的文件均保留。删除后不能再通过这条记录撤销整理。")
        }
    }
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择源文件夹").font(.title3.bold())
            HStack { Label("拖入一个或多个文件夹", systemImage: "folder.badge.plus"); Spacer(); Button("添加文件夹…") { model.chooseRoots() }; Button("清空选择") { model.clear() }.disabled(model.roots.isEmpty) }
            ForEach(model.roots, id: \.self) { url in
                HStack { Text(url.path).textSelection(.enabled).lineLimit(2); Spacer(); Button { model.removeRoot(url) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("移除 \(url.lastPathComponent)") }
            }
            Text("跳过隐藏项、应用包、符号链接及重复路径；不会扫描整理结果目录。").font(.caption).foregroundStyle(AppColors.textSecondary)
        }.padding(20).background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(dropTargeted ? AppColors.primary : .clear, lineWidth: 2)).disabled(model.busy)
        .dropDestination(for: URL.self) { urls, _ in guard !model.busy else { return false }; model.addRoots(urls); return true } isTargeted: { dropTargeted = $0 }
    }
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("2. 设置整理方式").font(.title3.bold())
            HStack { Picker("操作", selection: $model.mode) { ForEach(OrganizerMode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).frame(width: 240); Spacer(); Toggle("包含子文件夹", isOn: $model.recursive).toggleStyle(.checkbox) }
            HStack { Text("整理位置").font(.headline); Text(model.destination?.path ?? "添加源文件夹后默认使用“整理结果”").textSelection(.enabled).lineLimit(2); Spacer(); Button("更改位置…") { model.chooseDestination() } }
            Picker("同名文件", selection: $model.conflict) { ForEach(OrganizerConflict.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 340)
            HStack { Text("排除文件夹").font(.headline); Spacer(); Button("添加排除项…") { model.chooseExclusions() } }
            ForEach(model.excluded, id: \.self) { url in
                HStack { Text(url.path).font(.callout).lineLimit(2); Spacer(); Button("移除") { model.removeExclusion(url) } }
            }
            if model.mode == .copy { Text("复制保留源文件；确认预览后才会创建分类文件夹。").font(.callout).foregroundStyle(AppColors.textSecondary) }
            else { Text("移动会改变原路径。开始前会再次提示确认。").font(.callout).foregroundStyle(.orange) }
        }.padding(20).background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 14)).disabled(model.busy)
    }
    private func previewSection(_ plan: OrganizerPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("3. 整理预览").font(.title3.bold()); Spacer(); Text("可执行 \(plan.actionable.count) 个 · \(FileUtils.formatSize(Int64(clamping: plan.totalBytes)))").foregroundStyle(AppColors.textSecondary) }
            ForEach(plan.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            Text("文件会放到下方对应的分类文件夹中。展开查看文件及来源；跳过项不会执行，设置变化后需重新预览。").font(.callout).foregroundStyle(AppColors.textSecondary)
            OrganizerFolderTree(items: plan.items, configuration: plan.configuration, isPreview: true)
            Button("按预览\(plan.configuration.mode.rawValue) \(plan.actionable.count) 个文件") { if model.mode == .move { confirmMove = true } else { model.execute() } }
                .buttonStyle(.borderedProminent).disabled(!model.canExecute)
        }
    }
    private func resultSection(_ journal: OrganizerJournal) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("整理记录与结果").font(.title3.bold()); Spacer(); Button("打开整理文件夹") { model.revealDestination() }.disabled(model.busy); Button("撤销这次整理") { confirmUndo = true }.disabled(!model.canUndo) }
            if !model.records.isEmpty {
                HStack {
                    Picker("查看记录（最近 20 次）", selection: Binding(get: { journal.id }, set: { model.selectRecord($0) })) {
                        ForEach(model.records) { record in Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.configuration.mode.rawValue) · \(record.items.count) 个文件").tag(record.id) }
                    }.disabled(model.busy)
                    Button(role: .destructive) { recordToDelete = journal; confirmDeleteRecord = true } label: {
                        Label("删除这条记录", systemImage: "trash")
                    }.disabled(!model.canDeleteRecord)
                }
            }
            Text("\(journal.configuration.mode.rawValue)至 \(journal.configuration.destination.path)").font(.callout).textSelection(.enabled)
            Text(journal.summary).font(.headline)
            if let error = journal.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            Text("按目标文件夹查看分类，文件右侧显示实际处理状态。失败、跳过、未处理和已撤销的项目不代表已放入该文件夹。")
                .font(.caption).foregroundStyle(AppColors.textSecondary)
            OrganizerFolderTree(items: journal.items, configuration: journal.configuration, isPreview: false)
            Text("记录保存在本机，包含路径、时间和校验值；重启后仍可查看与撤销。取消或部分失败后，已生成且未变化的副本也可撤销。").font(.caption).foregroundStyle(AppColors.textSecondary)
        }.padding(20).background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 14))
    }
}
