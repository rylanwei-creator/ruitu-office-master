#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 批量文件改名页面

struct FileRenameView: View {
    @State private var viewModel = FileRenameViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 页面标题
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            if let logoPath = AppResources.bundle.path(forResource: "Logo", ofType: "png"),
                               let nsImage = NSImage(contentsOfFile: logoPath) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 36, height: 36)
                            }
                            Text("文件改名")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(AppColors.textPrimary)
                        }
                        Text("批量修改文件名，支持添加前缀/后缀、查找替换、序号命名")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .padding(.top, 24)

                    // 第一步：选择文件
                    fileSelectionSection
                    .disabled(viewModel.isProcessing)

                    // 已选文件列表
                    if !viewModel.selectedFiles.isEmpty {
                        selectedFileList
                    }

                    // 第二步：改名设置
                    if !viewModel.selectedFiles.isEmpty {
                        renameConfigSection
                    .disabled(viewModel.isProcessing)

                        // 第三步：预览
                        if viewModel.hasPreview {
                            previewSection
                        }

                        // 第四步：执行
                        executeSection
                    }
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 900)
            }

            // 隐私声明 — 固定在底部，不随内容滚动
            privacyNotice
                .padding(.bottom, 8)
        }
        .background(AppColors.background)
        // 任何参数变化时自动重新生成预览（延迟到编辑完成后）
        .onChange(of: viewModel.renameMode) { viewModel.generatePreview() }
        .onChange(of: viewModel.prefixText) { viewModel.generatePreview() }
        .onChange(of: viewModel.suffixText) { viewModel.generatePreview() }
        .onChange(of: viewModel.findText) { viewModel.generatePreview() }
        .onChange(of: viewModel.replaceText) { viewModel.generatePreview() }
        .onChange(of: viewModel.numberText) { viewModel.generatePreview() }
        .onChange(of: viewModel.startNumber) { viewModel.generatePreview() }
        .onChange(of: viewModel.numberDigits) { viewModel.generatePreview() }
    }

    // MARK: - 文件选择区域

    private var fileSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择文件")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            // 拖拽区域 + 按钮
            VStack(spacing: 12) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 32))
                    .foregroundColor(AppColors.textSecondary.opacity(0.5))

                Text("拖拽文件到此处，或点击下方按钮选择")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)

                HStack(spacing: 12) {
                    Button(action: { viewModel.selectFiles() }) {
                        Label("选择文件", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    if !viewModel.selectedFiles.isEmpty {
                        Button(action: { viewModel = FileRenameViewModel() }) {
                            Label("清空列表", systemImage: "trash")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        AppColors.textSecondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
            )
            .background(AppColors.cardBackground.opacity(0.6))
            .cornerRadius(10)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
                return true
            }
        }
    }

    // MARK: - 已选文件列表

    private var selectedFileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(viewModel.fileCountText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppColors.primaryLight.opacity(0.35))

            // 文件行（支持拖拽排序）
            List {
                ForEach(viewModel.selectedFiles, id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary.opacity(0.4))

                        Image(systemName: "doc")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.primary)

                        Text(url.lastPathComponent)
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Button(action: { viewModel.removeFile(url: url) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(AppColors.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .onMove(perform: viewModel.moveFiles)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: max(CGFloat(viewModel.selectedFiles.count) * 36, 40))
        }
        .background(AppColors.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - 改名配置

    private var renameConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. 改名设置")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: 16) {
                // 模式选择（纯绑定，无副作用）
                Picker("改名模式", selection: Binding(
                    get: { viewModel.renameMode },
                    set: { viewModel.renameMode = $0 }
                )) {
                    ForEach(RenameMode.allCases, id: \.self) { mode in
                        Label(mode.rawValue, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                // 参数输入（按模式不同）
                modeParameters
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
    }

    // MARK: - 模式参数

    @ViewBuilder
    private var modeParameters: some View {
        switch viewModel.renameMode {
        case .prefix:
            VStack(alignment: .leading, spacing: 6) {
                Text("添加前缀")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                TextField("例如: vacation_", text: Binding(
                    get: { viewModel.prefixText },
                    set: { viewModel.prefixText = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            }

        case .suffix:
            VStack(alignment: .leading, spacing: 6) {
                Text("添加后缀（在扩展名前）")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                TextField("例如: _final", text: Binding(
                    get: { viewModel.suffixText },
                    set: { viewModel.suffixText = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            }

        case .replace:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("查找文字")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("待替换的文字", text: Binding(
                        get: { viewModel.findText },
                        set: { viewModel.findText = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("替换为")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("新文字", text: Binding(
                        get: { viewModel.replaceText },
                        set: { viewModel.replaceText = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                }
            }

        case .numbering:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("名称前缀")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("例如: 照片", text: Binding(
                        get: { viewModel.numberText },
                        set: { viewModel.numberText = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("起始编号")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("1", value: Binding(
                        get: { viewModel.startNumber },
                        set: { viewModel.startNumber = $0 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("编号位数")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    Picker("", selection: Binding(
                        get: { viewModel.numberDigits },
                        set: { viewModel.numberDigits = $0 }
                    )) {
                        Text("2位").tag(2)
                        Text("3位").tag(3)
                        Text("4位").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
            }
        }
    }

    // MARK: - 预览列表

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. 改名预览")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                + Text("  (\(viewModel.selectedFiles.count) 个文件)")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)

            // 冲突警告
            if viewModel.hasConflicts {
                Label("\(viewModel.conflictCount) 个文件存在冲突（目标已存在或无权限），执行时将自动避让", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }

            VStack(spacing: 0) {
                // 表头
                HStack(spacing: 16) {
                    Text("原文件名")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    Text("新文件名")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppColors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppColors.primaryLight.opacity(0.5))

                // 预览行
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(viewModel.previewItems) { item in
                            previewRow(item)
                            Divider()
                                .foregroundColor(AppColors.textSecondary.opacity(0.15))
                        }
                    }
                }
                .frame(maxHeight: 250)
            }
            .background(AppColors.cardBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private func previewRow(_ item: RenamePreviewItem) -> some View {
        HStack(spacing: 16) {
            Text(item.originalName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(AppColors.textSecondary)

            Image(systemName: "arrow.right")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary.opacity(0.5))

            Text(item.newName)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(previewRowColor(item))

            if let reason = item.conflictReason {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .help(reason)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func previewRowColor(_ item: RenamePreviewItem) -> Color {
        if item.conflictReason != nil { return .orange }
        return item.isValid ? AppColors.primary : AppColors.textPrimary
    }

    // MARK: - 执行区域

    private var executeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 进度条
            if viewModel.isProcessing {
                ProgressBar(
                    progress: Binding(
                        get: { viewModel.progress },
                        set: { _ in }
                    ),
                    currentFile: viewModel.currentFileName
                )
            }

            // 执行按钮
            HStack(spacing: 12) {
                Button(action: { viewModel.executeRename() }) {
                    Label("执行改名", systemImage: "checkmark.circle")
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canExecute)
                if viewModel.canUndo {
                    Button("撤销上次改名", action: { viewModel.undoRename() }).buttonStyle(.bordered)
                }

                // 消息提示
                if let msg = viewModel.successMessage {
                    Label(msg, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.success)
                }
                if let msg = viewModel.errorMessage {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.error)
                }
            }
        }
    }

    // MARK: - 拖拽处理

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        viewModel.addFiles(from: [url])
                    }
                }
            }
        }
    }

    // MARK: - 隐私声明

    private var privacyNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 12))
                .foregroundColor(AppColors.success)
            Text("文件工具在本机处理；语音识别仅使用本地能力，反馈功能需联网")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 12)
    }
}

#endif
