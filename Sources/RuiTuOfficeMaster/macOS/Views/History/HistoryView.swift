#if os(macOS)
import SwiftUI

/// 历史记录页面
struct HistoryView: View {
    @State private var viewModel = HistoryViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                titleSection
                toolbarSection
                contentSection
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .frame(maxWidth: 900)
        }
        .background(AppColors.background)
        .onAppear { viewModel.loadRecords() }
    }

    // MARK: - 标题区

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let logoPath = AppResources.bundle.path(forResource: "Logo", ofType: "png"),
                   let nsImage = NSImage(contentsOfFile: logoPath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                }
                Text("历史记录")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
            }
            Text("查看所有文件处理操作记录")
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
        }
    }

    // MARK: - 搜索筛选栏

    private var toolbarSection: some View {
        HStack(spacing: 12) {
            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppColors.textSecondary)
                TextField("搜索文件名或描述...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(AppColors.cardBackground)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppColors.textSecondary.opacity(0.2), lineWidth: 1)
            )

            // 工具筛选
            Picker("工具筛选", selection: $viewModel.selectedToolFilter) {
                Text("全部工具").tag(nil as String?)
                ForEach(viewModel.availableTools, id: \.self) { tool in
                    Text(tool).tag(tool as String?)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            Spacer()

            // 手动刷新按钮（兜底容错）
            Button {
                viewModel.loadRecords()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("手动刷新列表")

            // 清空按钮
            if !viewModel.records.isEmpty {
                Button {
                    viewModel.clearAll()
                } label: {
                    Text("清空全部")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.error)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AppColors.error.opacity(0.08))
                .cornerRadius(6)
            }
        }
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentSection: some View {
        if viewModel.records.isEmpty {
            emptyState
        } else if viewModel.filteredRecords.isEmpty {
            noSearchResults
        } else {
            recordList
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 60)
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 48))
                .foregroundColor(AppColors.textSecondary.opacity(0.5))
            Text("暂无历史记录")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(AppColors.textSecondary)
            Text("使用任意工具处理文件后，记录将自动出现在这里")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 无搜索结果

    private var noSearchResults: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 40)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(AppColors.textSecondary.opacity(0.5))
            Text("未找到匹配的记录")
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 记录列表

    private var recordList: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                recordHeader

                LazyVStack(spacing: 0) {
                    ForEach(viewModel.filteredRecords, id: \.id) { record in
                        RecordRow(
                            record: record,
                            isExpanded: viewModel.isExpanded(record.id),
                            onToggle: { viewModel.toggleExpand(record.id) },
                            onDelete: { viewModel.deleteRecord(record) }
                        )
                        Divider()
                            .foregroundColor(AppColors.textSecondary.opacity(0.1))
                    }
                }
                .background(AppColors.cardBackground)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(AppColors.textSecondary.opacity(0.15), lineWidth: 1)
                )
            }

            privacyNote
        }
    }

    // MARK: - 表头

    private var recordHeader: some View {
        HStack(spacing: 12) {
            Text("时间").frame(width: 130, alignment: .leading)
            Text("操作").frame(width: 100, alignment: .leading)
            Text("文件数").frame(width: 50, alignment: .center)
            Text("状态").frame(width: 60, alignment: .center)
            Spacer()
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(AppColors.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppColors.textSecondary.opacity(0.05))
    }

    // MARK: - 隐私声明

    private var privacyNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundColor(AppColors.textSecondary.opacity(0.5))
            Text("历史记录仅存储在本设备，不上传云端")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary.opacity(0.5))
        }
        .padding(.top, 8)
    }
}

// MARK: - 单条记录行

private struct RecordRow: View {
    let record: HistoryRecord
    let isExpanded: Bool
    let onToggle: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 0) {
            // 主行
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    // 时间
                    Text(record.timestamp, style: .date)
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textPrimary)
                        .frame(width: 80, alignment: .leading)
                    Text(record.timestamp, style: .time)
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                        .frame(width: 50, alignment: .leading)

                    // 操作类型
                    HStack(spacing: 6) {
                        Image(systemName: toolIcon(for: record.toolName))
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.primary)
                        Text(record.operationType)
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    .frame(width: 120, alignment: .leading)

                    // 文件数
                    Text("\(record.fileCount) 个")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                        .frame(width: 50, alignment: .center)

                    // 状态
                    statusBadge
                        .frame(width: 60, alignment: .center)

                    Spacer()

                    // 展开指示器
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(AppColors.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    // 删除按钮
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering ? 1 : 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isHovering ? AppColors.primaryLight.opacity(0.3) : Color.clear)
            .onHover { isHovering = $0 }

            // 展开详情
            if isExpanded {
                detailSection
            }
        }
    }

    // MARK: - 状态标签

    private var statusBadge: some View {
        Text(record.status)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.1))
            .cornerRadius(4)
    }

    private var statusColor: Color {
        switch record.status {
        case "成功": return AppColors.success
        case "失败": return AppColors.error
        default:    return Color(hex: "#FF9500")
        }
    }

    // MARK: - 展开详情

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .foregroundColor(AppColors.textSecondary.opacity(0.1))

            // 描述
            Text(record.descriptionText)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
                .padding(.horizontal, 16)

            // 大小对比
            if record.inputSize > 0 {
                HStack(spacing: 8) {
                    Text("处理前：\(formatBytes(record.inputSize))")
                    Text("→")
                    Text("处理后：\(formatBytes(record.outputSize))")
                    if record.inputSize > 0 {
                        let ratio = Double(record.outputSize) / Double(record.inputSize)
                        let pct = Int((1 - ratio) * 100)
                        if pct > 0 {
                            Text("节省 \(pct)%")
                                .foregroundColor(AppColors.success)
                        }
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary)
                .padding(.horizontal, 16)
            }

            // 文件列表
            if !record.inputFileNames.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("处理文件：")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(AppColors.textSecondary)
                    ForEach(record.inputFileNames, id: \.self) { name in
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary.opacity(0.8))
                    }
                }
                .padding(.horizontal, 16)
            }

            Spacer().frame(height: 8)
        }
        .background(AppColors.textSecondary.opacity(0.03))
    }

    // MARK: - 辅助

    private func toolIcon(for toolName: String) -> String {
        NavItem.allCases.first { $0.rawValue == toolName }?.systemImage ?? "doc"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#endif
