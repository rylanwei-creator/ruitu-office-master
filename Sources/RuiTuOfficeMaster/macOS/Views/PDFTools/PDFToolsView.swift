#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - PDF 工具页面

struct PDFToolsView: View {
    @State private var viewModel = PDFToolsViewModel()

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
                        Text("PDF 工具")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    Text("合并、拆分、加密、水印、格式转换，一站式 PDF 处理")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.top, 24)

                // 子功能介绍
                featureIntroSection

                // 工具选择器
                toolPickerSection
                    .disabled(viewModel.isBusy)

                // 第一步：选择文件
                fileSelectionSection
                    .disabled(viewModel.isBusy)

                // 配置 + 执行
                if !viewModel.selectedFiles.isEmpty {
                    if viewModel.selectedTool == .split {
                        PDFSplitPreviewView(viewModel: viewModel)
                    }
                    configSection
                    .disabled(viewModel.isBusy)
                    executeSection

                    if !viewModel.entries.isEmpty {
                        fileStatusSection
                    }

                    if !viewModel.results.isEmpty {
                        resultsSection
                    }
                }

            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }

        privacyNotice
            .padding(.bottom, 8)
    }
    .background(AppColors.background)
    }

    // MARK: - 子功能介绍

    private var featureIntroSection: some View {
        HStack(spacing: 16) {
            FeatureIntroItem(
                icon: "doc.on.doc",
                title: "合并 PDF",
                desc: "多个 PDF 按顺序合并为一个完整文件，支持拖拽排序"
            )
            FeatureIntroItem(
                icon: "doc.on.doc.fill",
                title: "拆分 PDF",
                desc: "按页码范围拆分或逐页提取为独立文件"
            )
            FeatureIntroItem(
                icon: "lock.doc",
                title: "加密保护",
                desc: "设置打开密码与权限密码，控制打印与复制权限"
            )
            FeatureIntroItem(
                icon: "doc.richtext",
                title: "水印添加",
                desc: "支持文字或图片水印，可自定义旋转角度与透明度"
            )
        }
    }

    // MARK: - 工具选择器

    private var toolPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选择工具")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            Picker("工具", selection: $viewModel.selectedTool) {
                ForEach(PDFTool.allCases, id: \.self) { tool in
                    Text(tool.rawValue).tag(tool)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 文件选择

    private var fileSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择文件")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            // 拖拽区域
            VStack(spacing: 12) {
                Image(systemName: fileSelectionIcon)
                    .font(.system(size: 36))
                    .foregroundColor(AppColors.textSecondary.opacity(0.6))

                Text(fileSelectionHint)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)

                HStack(spacing: 12) {
                    Button(action: { viewModel.selectFiles() }) {
                        Label("选择文件", systemImage: "plus.circle")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    if !viewModel.selectedFiles.isEmpty {
                        Button(action: { viewModel.clearFiles() }) {
                            Label("清空列表", systemImage: "trash")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(white: 0.78), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
                return true
            }

            // 文件列表
            if !viewModel.selectedFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(viewModel.fileCountText)（\(viewModel.originalTotalSizeText)）")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary)
                        Spacer()
                    }

                    if viewModel.selectedTool == .merge {
                        Text("文件将按列表顺序从上到下合并，可拖拽调整顺序")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary.opacity(0.7))
                    }

                    VStack(spacing: 4) {
                        ForEach(viewModel.selectedFiles, id: \.self) { url in
                            fileRow(url: url)
                        }
                        .onMove { source, destination in
                            if viewModel.selectedTool == .merge {
                                viewModel.moveFiles(from: source, to: destination)
                            }
                        }
                    }
                }
                .padding(16)
                .background(AppColors.cardBackground)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(white: 0.88), lineWidth: 1)
                )
            }
        }
    }

    private func fileRow(url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.fill")
                .font(.system(size: 14))
                .foregroundColor(AppColors.primary)

            Text(url.lastPathComponent)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .help(url.path)

            Spacer()

            if viewModel.selectedTool == .split, viewModel.splitPreview.selectedURL == url {
                Text(viewModel.splitPreview.pageCount.map { "共 \($0) 页" }
                     ?? (viewModel.splitPreview.isLoadingDocument ? "读取页数中…" : "页数不可读"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.primary)
            }

            Text(FileUtils.formatSize(viewModel.originalSizes[url] ?? 0))
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary)

            if viewModel.selectedTool == .merge {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary.opacity(0.5))
            }

            Button(action: { removeFileSafely(url: url) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppColors.background.opacity(0.5))
        )
    }

    // MARK: - 配置区域（随工具切换）

    @ViewBuilder
    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. 配置")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: 16) {
                switch viewModel.selectedTool {
                case .merge:
                    mergeConfig
                case .split:
                    splitConfig
                case .encrypt:
                    encryptConfig
                case .watermark:
                    watermarkConfig
                case .conversion:
                    conversionConfig
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )
        }
    }

    // MARK: 合并配置

    private var mergeConfig: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.primary)
                Text("已选择 \(viewModel.selectedFiles.count) 个 PDF，将按列表顺序从上到下合并为一个文件")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
            }
            Text("提示：可在文件列表中拖拽调整合并顺序")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
        }
    }

    // MARK: 拆分配置

    private var splitConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            @Bindable var vm = viewModel

            HStack(spacing: 8) {
                Text("页码范围：")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)

                TextField("例: 1-3, 5, 7-10", text: $vm.splitRangesText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .font(.system(size: 13))
            }

            Text("使用逗号分隔多个范围，如「1-3, 5, 7-10」表示提取第 1-3 页、第 5 页、第 7-10 页")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))

            if let error = viewModel.splitRangeError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundColor(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if viewModel.splitRangesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("请输入要拆分的页码范围；每个逗号分隔的范围会生成一份 PDF。")
                    .font(.system(size: 12)).foregroundColor(AppColors.textSecondary)
            } else if !viewModel.parsePageRangesForDisplay.isEmpty {
                Text("将生成 \(viewModel.splitPreviewRanges.count) 个文件，共 \(viewModel.splitOutputPageCount) 页（重叠范围分别计数）")
                    .font(.system(size: 12)).foregroundColor(AppColors.success)
                ViewThatFits(in: .horizontal) {
                    HStack { splitRangeButtons }
                    VStack(alignment: .leading) { splitRangeButtons }
                }
            }

        }
    }

    private var splitRangeButtons: some View {
        ForEach(Array(viewModel.splitPreviewRanges.enumerated()), id: \.offset) { index, range in
            Button("文件 \(index + 1)：第 \(range.start)" + (range.start == range.end ? " 页" : "–\(range.end) 页")) {
                viewModel.splitPreview.goToPage(range.start)
            }
            .buttonStyle(.bordered)
            .help("预览这个范围的第一页")
        }
    }

    // MARK: 加密配置

    private var encryptConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            @Bindable var vm = viewModel

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("用户密码（打开文件）")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)
                    SecureField("必填", text: $vm.userPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("所有者密码（权限控制）")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)
                    SecureField("可选", text: $vm.ownerPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
            }

            HStack(spacing: 24) {
                Toggle("允许打印", isOn: $vm.allowPrinting)
                    .font(.system(size: 13))
                Toggle("允许复制内容", isOn: $vm.allowCopying)
                    .font(.system(size: 13))
            }

            Text("用户密码用于打开 PDF 文件，所有者密码用于限制打印/复制等权限")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
            if !viewModel.userPassword.isEmpty, viewModel.userPassword == viewModel.ownerPassword {
                Text("打开密码与权限密码不能相同")
                    .font(.caption).foregroundStyle(AppColors.error)
            }
        }
    }

    // MARK: 水印配置

    private var watermarkConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            @Bindable var vm = viewModel

            Picker("水印类型", selection: $vm.watermarkUIType) {
                ForEach(WatermarkUIType.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            switch viewModel.watermarkUIType {
            case .text:
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("水印文字")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                        TextField("机密", text: $vm.watermarkText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("字号: \(Int(viewModel.watermarkFontSize))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                        Slider(value: $vm.watermarkFontSize, in: 20...120, step: 5)
                            .frame(width: 140)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("角度: \(Int(viewModel.watermarkRotation))°")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                        Slider(value: $vm.watermarkRotation, in: -90...90, step: 5)
                            .frame(width: 140)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("透明度: \(Int(viewModel.watermarkOpacity * 100))%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                        Slider(value: $vm.watermarkOpacity, in: 0.05...0.8, step: 0.05)
                            .frame(width: 140)
                    }
                }

            case .image:
                HStack(spacing: 16) {
                    Button(action: { viewModel.selectWatermarkImage() }) {
                        if let imgURL = viewModel.watermarkImageURL {
                            Label(imgURL.lastPathComponent, systemImage: "photo")
                                .font(.system(size: 12))
                        } else {
                            Label("选择图片", systemImage: "photo.badge.plus")
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.bordered)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("透明度: \(Int(viewModel.watermarkOpacity * 100))%")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                        Slider(value: $vm.watermarkOpacity, in: 0.05...0.8, step: 0.05)
                            .frame(width: 140)
                    }
                }

                Text("图片将居中放置在每页 PDF 上，建议使用透明背景 PNG")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary.opacity(0.7))
            }
        }
    }

    // MARK: 格式转换配置

    private var conversionConfig: some View {
        VStack(alignment: .leading, spacing: 12) {
            @Bindable var vm = viewModel

            Picker("转换方向", selection: $vm.conversionDirection) {
                ForEach(ConversionDirection.allCases, id: \.self) { dir in
                    Text(dir.rawValue).tag(dir)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            VStack(alignment: .leading, spacing: 4) {
                switch viewModel.conversionDirection {
                case .wordToPDF:
                    Text("支持格式：.docx / .doc")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    Text("仅适用于基础文字文档；图片、复杂表格和分页布局可能无法保留，请检查转换结果")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary.opacity(0.7))
                case .pdfToWord:
                    Text("提取 PDF 中的文字内容")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    Text("转换结果为文本及基础格式，复杂排版和图片可能丢失")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary.opacity(0.7))
                }
            }
        }
    }

    // MARK: - 执行区域

    private var executeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. 执行")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(spacing: 12) {
                ActionButtons(
                    canExecute: viewModel.canExecute,
                    isProcessing: viewModel.isProcessing,
                    executeAction: { viewModel.execute() }
                )

                if viewModel.isProcessing {
                    Button(viewModel.cancellationRequested ? "正在停止…" : "停止处理") {
                        viewModel.stopProcessing()
                    }
                    .disabled(viewModel.cancellationRequested)
                    Text(viewModel.isMergeBatch
                         ? "合并会在页面之间检查停止请求；最终写入时需等待写入完成。"
                         : "停止后不再处理后续项；当前文件或拆分范围完成后保留结果。")
                        .font(.caption).foregroundStyle(AppColors.textSecondary)
                }

                if viewModel.isProcessing {
                    ProgressBar(
                        progress: $viewModel.progress,
                        currentFile: viewModel.currentFileName
                    )
                }

                // 消息提示
                if let msg = viewModel.successMessage {
                    Label(msg, systemImage: viewModel.wasStopped ? "stop.circle" : (viewModel.failedCount > 0 ? "info.circle" : "checkmark.circle.fill"))
                        .font(.system(size: 13))
                        .foregroundColor(viewModel.wasStopped || viewModel.failedCount > 0 || viewModel.unfinishedCount > 0 ? .orange : AppColors.success)
                        .padding(.top, 4)
                }
                if let msg = viewModel.errorMessage {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.error)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )
        }
    }

    // MARK: - 结果区域

    private var fileStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(viewModel.isMergeBatch ? "源文件状态" : "处理状态").font(.headline)
                Spacer()
                if viewModel.canRetry {
                    Button(viewModel.isMergeBatch ? "重新尝试合并" : "重试失败／未完成项（\(viewModel.retryCount)）") {
                        viewModel.retryUnfinished()
                    }.buttonStyle(.bordered)
                }
            }
            Text(viewModel.batchSummary).font(.callout).foregroundStyle(AppColors.textSecondary)
            if viewModel.isMergeBatch {
                Text("所有源文件都有效才会合并；失败后修复源文件并整组重试，不会跳过文件。")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            } else if viewModel.selectedTool == .split {
                Text("每个页码范围生成一个文件；重试会保留已成功的范围。")
                    .font(.caption).foregroundStyle(AppColors.textSecondary)
            }
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(viewModel.entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .top) {
                            Text(entry.title).textSelection(.enabled).help(entry.sourceURL.path)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(entry.state.rawValue)
                                .foregroundStyle(statusColor(entry.state))
                            if viewModel.canRetry, !viewModel.isMergeBatch, entry.state.canRetry {
                                Button("重试此项") { viewModel.retryEntry(entry.id) }
                                    .help("重试：\(entry.title)")
                            }
                        }.font(.callout)
                        if let error = entry.error {
                            Text(error).font(.caption).foregroundStyle(AppColors.error).textSelection(.enabled)
                        }
                    }
                    if entry.id != viewModel.entries.last?.id { Divider() }
                }
            }
        }
        .padding(16).background(AppColors.cardBackground).cornerRadius(10)
    }

    private func statusColor(_ state: PDFEntryState) -> Color {
        switch state {
        case .succeeded: AppColors.success
        case .failed: AppColors.error
        case .processing: AppColors.primary
        case .ready, .blocked: .orange
        case .waiting, .stopped: AppColors.textSecondary
        }
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("处理结果")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Button(action: { viewModel.saveResults() }) {
                    Label(viewModel.isSaving ? "正在保存…" : "保存到...", systemImage: "folder")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
            }

            VStack(spacing: 0) {
                // 表头
                HStack(spacing: 8) {
                    Text("文件名")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("操作")
                        .frame(width: 80, alignment: .center)
                    Text("原始大小")
                        .frame(width: 80, alignment: .trailing)
                    Text("处理后")
                        .frame(width: 80, alignment: .trailing)
                    Text("变化")
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(AppColors.primaryLight.opacity(0.5))

                Divider()

                ForEach(viewModel.results) { item in
                    resultRow(item: item)
                    if item.outputURL != viewModel.results.last?.outputURL {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .background(AppColors.cardBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(white: 0.88), lineWidth: 1)
            )
        }
    }

    private func resultRow(item: PDFResultItem) -> some View {
        HStack(spacing: 8) {
            Text(item.outputURL.lastPathComponent)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .help("来源：\(item.originalURL.path)\n结果：\(item.outputURL.path)")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.operationDescription)
                .font(.system(size: 11))
                .foregroundColor(AppColors.primary)
                .frame(width: 80, alignment: .center)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(AppColors.primaryLight)
                .cornerRadius(4)

            Text(FileUtils.formatSize(item.originalSize))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 80, alignment: .trailing)

            Text(FileUtils.formatSize(item.outputSize))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textPrimary)
                .frame(width: 80, alignment: .trailing)

            Text(item.changeText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(item.changePercent >= 0 ? AppColors.success : .orange)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - 隐私声明

    private var privacyNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 12))
                .foregroundColor(AppColors.success)
            Text("所有文档全程本地离线处理，文件不会上传到任何服务器")
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
        }
        .padding(.top, 8)
    }

    // MARK: - 辅助

    private var fileSelectionIcon: String {
        switch viewModel.selectedTool {
        case .conversion: return "arrow.triangle.swap"
        default: return "doc.fill"
        }
    }

    private var fileSelectionHint: String {
        switch viewModel.selectedTool {
        case .merge: return "拖拽或点击选择要合并的 PDF 文件（至少 2 个）"
        case .split: return "拖拽或点击选择要拆分的 PDF 文件"
        case .encrypt: return "拖拽或点击选择要加密的 PDF 文件"
        case .watermark: return "拖拽或点击选择要添加水印的 PDF 文件"
        case .conversion: return "拖拽或点击选择要转换的文件（.pdf / .docx / .doc）"
        }
    }

    private func removeFileSafely(url: URL) {
        viewModel.removeFile(url: url)
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                guard let urlData = data as? Data,
                      let url = URL(dataRepresentation: urlData, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    viewModel.addFiles(from: [url])
                }
            }
        }
    }
}

// MARK: - 执行按钮

private struct ActionButtons: View {
    let canExecute: Bool
    let isProcessing: Bool
    let executeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: executeAction) {
                Label(
                    isProcessing ? "处理中..." : "开始处理",
                    systemImage: isProcessing ? "hourglass" : "play.fill"
                )
                .font(.system(size: 14, weight: .medium))
                .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canExecute)
        }
    }
}

#endif
