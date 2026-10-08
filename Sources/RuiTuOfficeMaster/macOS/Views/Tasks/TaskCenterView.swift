import SwiftUI
import AppKit

struct TaskCenterView: View {
    @State private var manager = FileTaskManager.shared
    @State private var showClear = false
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PageHeader(title: "任务中心", subtitle: "图片处理与格式转换的队列、进度和结果；其他工具仍在各自页面查看")
                    HStack {
                        Text("\(manager.activeCount) 个处理中或等待中 · 最近 \(manager.records.count) 条任务").foregroundStyle(AppColors.textSecondary)
                        Spacer()
                        Button("清除已结束记录") { showClear = true }.disabled(manager.records.allSatisfy { $0.state.isActive })
                    }
                    if let error = manager.persistenceError {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if manager.records.isEmpty {
                        Spacer(minLength: 0)
                        ContentUnavailableView("暂无任务", systemImage: "list.bullet.clipboard", description: Text("在图片处理或格式转换中开始批量处理，任务会显示在这里。"))
                            .frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(manager.records) { record in
                                TaskRecordCard(record: record, manager: manager)
                            }
                        }
                    }
                }
                .frame(minHeight: manager.records.isEmpty ? max(0, geometry.size.height - 64) : nil, alignment: .top)
                .padding(32)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }.background(AppColors.background)
        .alert("清除已结束的任务记录？", isPresented: $showClear) {
            Button("取消", role: .cancel) {}
            Button("清除记录", role: .destructive) { manager.clearFinished() }
        } message: { Text("只清除任务中心记录，不删除原文件、结果文件或历史记录。") }
    }
}

private struct TaskRecordCard: View {
    let record: FileTaskRecord
    let manager: FileTaskManager
    @State private var expanded = false
    private var availableResults: [URL] {
        record.files.compactMap { entry in
            [entry.savedURL, entry.output?.url].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(record.tool, systemImage: record.tool == "图片处理" ? "photo" : "photo.stack").font(.headline)
                Spacer()
                Text(record.state.title).font(.callout).foregroundStyle(statusColor(record.state))
                Text(record.createdAt, style: .time).font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            Text(record.configuration).font(.caption).foregroundStyle(AppColors.textSecondary)
            ProgressView(value: record.progress).tint(AppColors.primary)
            Text(record.summary).font(.callout).textSelection(.enabled)
            if record.state.isActive {
                Text(record.cancellationRequested ? "正在停止，等待当前图片编码结束…" : record.currentFile)
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
                Text("按已处理文件数计算进度，单张图片编码不提供实时百分比。")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            HStack {
                if record.state.isActive {
                    Button(record.cancellationRequested ? "正在停止…" : "停止任务") { manager.cancel(record.id) }
                        .disabled(record.cancellationRequested)
                }
                if manager.canRetry(record.id) {
                    Button("重试未完成项（\(record.retryCount)）") { manager.retry(record.id) }
                }
                if record.succeeded > 0 {
                    Button(manager.savingIDs.contains(record.id) ? "正在保存…" : "保存成功结果…") {
                        Task { await manager.saveResults(record.id) }
                    }.disabled(record.state.isActive || manager.savingIDs.contains(record.id) || availableResults.isEmpty)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(availableResults) }
                        .disabled(availableResults.isEmpty)
                }
            }.buttonStyle(.bordered)
            if let message = manager.exportMessages[record.id] { Text(message).font(.callout).foregroundStyle(AppColors.textSecondary) }
            if let error = manager.exportErrors[record.id] { Text(error).font(.caption).foregroundStyle(AppColors.error).textSelection(.enabled) }
            if !record.state.isActive, record.succeeded > 0, availableResults.isEmpty {
                Text("结果文件已清理或移动，记录仍保留。请返回工具重新处理。")
                    .font(.caption).foregroundStyle(.orange)
            }
            DisclosureGroup("文件详情（\(record.files.count)）", isExpanded: $expanded) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(record.files) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.source.lastPathComponent).lineLimit(1).help(entry.source.path)
                                Spacer()
                                Text(entry.state.title).foregroundStyle(statusColor(entry.state))
                                if let output = entry.output { Text(FileUtils.formatSize(output.outputSize)).monospacedDigit() }
                            }
                            if let error = entry.error { Text(error).foregroundStyle(AppColors.error).textSelection(.enabled) }
                        }.font(.caption)
                    }
                }.padding(.top, 8)
            }
        }
        .padding(20).background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 12))
    }
    private func statusColor(_ state: FileTaskState) -> Color {
        switch state {
        case .completed: return AppColors.success
        case .failed, .partial: return AppColors.error
        case .cancelled, .interrupted: return .orange
        default: return AppColors.textSecondary
        }
    }
}
