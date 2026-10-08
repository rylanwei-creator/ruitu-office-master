#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
import AppKit
import Translation

// MARK: - 音视频转换页面

struct MediaConversionView: View {
    @State private var viewModel = MediaConversionViewModel()
    @State private var dragOver = false

    var body: some View {
        VStack(spacing: 0) {
            let content = ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                titleSection
                featureIntroSection
                toolPickerSection
                    .disabled(viewModel.isProcessing)
                fileSelectionSection
                    .disabled(viewModel.isProcessing)
                if !viewModel.selectedFiles.isEmpty {
                    configSection
                    .disabled(viewModel.isProcessing)
                }
                executeSection
                if !viewModel.results.isEmpty {
                    resultsSection
                }
                if viewModel.selectedTool == .speechToText && viewModel.hasTranscribedResults {
                    if viewModel.subtitleFormat == .plainText {
                        fullTextPreviewSection
                    } else {
                        subtitleEditorSection
                    }
                }
                Spacer(minLength: 48)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 900)
        }
        .background(AppColors.background)

        if #available(macOS 15.0, *) {
            content.translationTask(source: nil, target: nil) { session in
                viewModel.setTranslationSession(session)
            }
        } else {
            content
        }

        privacyNotice
            .padding(.bottom, 8)
    }
    .background(AppColors.background)
    }

    // MARK: 标题

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
                Text("音视频转换")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
            }
            Text("语音转字幕、GIF 生成与压缩，全部本地离线运行")
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.top, 24)
    }

    // MARK: 功能介绍卡片

    private var featureIntroSection: some View {
        HStack(alignment: .top, spacing: 16) {
            FeatureIntroItem(
                icon: "waveform",
                title: "语音转字幕",
                desc: "会议录音、视频文件一键转录为 SRT/VTT/TXT 字幕，支持多语言识别"
            )
            FeatureIntroItem(
                icon: "film",
                title: "GIF 生成与压缩",
                desc: "最长 60 秒片段转 GIF，支持缩小尺寸与减少帧数"
            )
        }
    }

    // MARK: 工具选择器

    private var toolPickerSection: some View {
        Picker("工具", selection: $viewModel.selectedTool) {
            ForEach(MediaConversionTool.allCases, id: \.self) { tool in
                Text(tool.rawValue).tag(tool)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: viewModel.selectedTool) {
            viewModel.results = []
            viewModel.selectedFiles = []
            viewModel.originalSizes = [:]
        }
    }

    // MARK: 文件选择区域

    private var fileSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择文件")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            // 拖拽区域
            dragDropZone

            // 文件列表
            if !viewModel.selectedFiles.isEmpty {
                fileListSection
            }
        }
    }

    private var dragDropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: dropZoneIcon)
                .font(.system(size: 32))
                .foregroundColor(dragOver ? AppColors.primary : AppColors.textSecondary)
            Text(dropZoneHint)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
            HStack(spacing: 12) {
                Button("选择文件") {
                    viewModel.selectFiles()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.primary)

                if !viewModel.selectedFiles.isEmpty {
                    Button("清空列表") {
                        viewModel = MediaConversionViewModel()
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    dragOver ? AppColors.primary : Color(white: 0.78),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(dragOver ? AppColors.primary.opacity(0.05) : Color.clear)
        )
        .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private var dropZoneIcon: String {
        switch viewModel.selectedTool {
        case .speechToText: return "waveform.badge.mic"
        case .gifGeneration: return "film"
        }
    }

    private var dropZoneHint: String {
        switch viewModel.selectedTool {
        case .speechToText:
            return "拖入音频或视频文件，自动识别语音并生成字幕"
        case .gifGeneration:
            return "拖入视频或 GIF 文件，生成或压缩 GIF"
        }
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

    // MARK: 文件列表

    private var fileListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(viewModel.fileCountText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
                Text("·")
                    .foregroundColor(AppColors.textSecondary)
                Text(viewModel.originalTotalSizeText)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
            }

            ForEach(viewModel.selectedFiles, id: \.self) { url in
                fileRow(url)
            }
        }
    }

    private func fileRow(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: fileIcon(for: url))
                .foregroundColor(AppColors.primary)
                .frame(width: 20)
            Text(url.lastPathComponent)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
            Spacer()
            if let size = viewModel.originalSizes[url] {
                Text(FileUtils.formatSize(size))
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
            }
            Button {
                removeFileSafely(url)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(AppColors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(AppColors.cardBackground)
        )
    }

    private func fileIcon(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "avi", "m4v", "mkv": return "film"
        case "mp3", "m4a", "wav", "aiff", "aac", "flac", "caf": return "waveform"
        case "gif": return "photo"
        default: return "doc"
        }
    }

    private func removeFileSafely(_ url: URL) {
        if viewModel.selectedFiles.count == 1 {
            viewModel = MediaConversionViewModel()
        } else {
            viewModel.removeFile(url: url)
        }
    }

    // MARK: 配置区域

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. 配置")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            Group {
                switch viewModel.selectedTool {
                case .speechToText: speechToTextConfig
                case .gifGeneration: gifConfig
                }
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppColors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(white: 0.88), lineWidth: 1)
            )
        }
    }

    // MARK: 语音转字幕配置

    private var speechToTextConfig: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 源语言
            VStack(alignment: .leading, spacing: 6) {
                Text("识别语言")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                Picker("识别语言", selection: $viewModel.sourceLanguage) {
                    ForEach(viewModel.supportedLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 250)
            }

            // 双语选项（macOS 15.0+，使用 Translation 框架本地离线翻译）
            if #available(macOS 15.0, *) {
                Toggle(isOn: $viewModel.showBilingualOption) {
                    Text("生成双语字幕")
                        .font(.system(size: 13))
                }
                .toggleStyle(.checkbox)

                if viewModel.showBilingualOption {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("目标翻译语言")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                        Picker("目标翻译语言", selection: $viewModel.targetLanguage) {
                            ForEach(viewModel.supportedLanguages, id: \.code) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 250)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    Text("双语字幕需要 macOS 15.0 或更高版本")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                }
            }

            // 字幕格式
            VStack(alignment: .leading, spacing: 6) {
                Text("导出格式")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                Picker("导出格式", selection: $viewModel.subtitleFormat) {
                    ForEach(SubtitleExportFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 250)
            }
        }
    }

    // MARK: GIF 配置

    private var gifConfig: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 帧率
            VStack(alignment: .leading, spacing: 6) {
                Text("帧率: \(viewModel.gifFrameRate) FPS")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                Slider(value: Binding(
                    get: { Double(viewModel.gifFrameRate) },
                    set: { viewModel.gifFrameRate = Int($0) }
                ), in: 5...30, step: 5)
                    .frame(maxWidth: 300)
                    .tint(AppColors.primary)
            }

            // 最大尺寸
            VStack(alignment: .leading, spacing: 6) {
                Text("最大尺寸")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                Picker("最大尺寸", selection: $viewModel.gifMaxSize) {
                    Text("240px").tag(CGFloat(240))
                    Text("480px").tag(CGFloat(480))
                    Text("720px").tag(CGFloat(720))
                    Text("1080px").tag(CGFloat(1080))
                }
                .pickerStyle(.segmented)
            }

            // 时长
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始时间（秒）")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("0", value: $viewModel.gifStartTime, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("持续时长（秒）")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("5", value: $viewModel.gifDuration, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }

            if viewModel.currentVideoDuration > 0 {
                Text("视频总时长: \(formatDuration(viewModel.currentVideoDuration))")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
            }

            // 微信提示
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                Text("微信推荐: 480px、10FPS、<20秒，输出更小更快")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(AppColors.primary.opacity(0.06))
            )
        }
    }

    // MARK: 执行区域

    private var executeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. 执行")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            if viewModel.isProcessing {
                ProgressBar(progress: $viewModel.progress, currentFile: viewModel.currentFileName)
                    .frame(height: 24)
            }

            HStack(spacing: 12) {
                Button(viewModel.isProcessing ? "处理中..." : "开始处理") {
                    viewModel.execute()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.primary)
                .disabled(!viewModel.canExecute || viewModel.isProcessing)

                if viewModel.isProcessing {
                    Button("取消") {
                        viewModel.cancelOperation()
                    }
                    .buttonStyle(.bordered)
                    .tint(AppColors.textSecondary)
                }
            }

            // 消息提示
            if let msg = viewModel.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.08))
                )
            }

            if let msg = viewModel.successMessage {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundColor(.green)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.08))
                )
            }
        }
    }

    // MARK: 结果区域

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("处理结果")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Button("保存到...") {
                    viewModel.saveResults()
                }
                .buttonStyle(.bordered)
                .tint(AppColors.primary)
            }

            // 表头
            HStack(spacing: 12) {
                Text("文件名").frame(maxWidth: .infinity, alignment: .leading)
                Text("操作").frame(width: 80, alignment: .leading)
                Text("原始大小").frame(width: 80, alignment: .trailing)
                Text("输出大小").frame(width: 80, alignment: .trailing)
                Text("节省").frame(width: 60, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(AppColors.textSecondary)
            .padding(.horizontal, 8)

            Divider()

            ForEach(viewModel.results) { item in
                resultRow(item)
                Divider()
            }
        }
    }

    private func resultRow(_ item: MediaConversionResultItem) -> some View {
        HStack(spacing: 12) {
            Text(item.originalURL.lastPathComponent)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(item.operationDescription)
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 80, alignment: .leading)

            Text(FileUtils.formatSize(item.originalSize))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 80, alignment: .trailing)

            Text(FileUtils.formatSize(item.outputSize))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textPrimary)
                .frame(width: 80, alignment: .trailing)

            Text("\(item.savedPercent)%")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(item.savedPercent == "0" ? AppColors.textSecondary : .green)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: 字幕编辑器

    private var subtitleEditorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("字幕编辑")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            ForEach(viewModel.results) { result in
                if let entries = result.subtitleEntries {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.originalURL.lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textSecondary)

                        ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                            subtitleEntryRow(resultID: result.id, entry: entry, index: idx)
                        }

                        Button("导出字幕") {
                            viewModel.reExportSubtitles(resultID: result.id)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppColors.primary)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppColors.cardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(white: 0.88), lineWidth: 1)
                    )
                }
            }
        }
    }

    private func subtitleEntryRow(resultID: UUID, entry: SubtitleEntry, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(entry.index)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
                Text("\(formatDuration(entry.startTime)) — \(formatDuration(entry.endTime))")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
            }

            @Bindable var vm = viewModel
            TextField("字幕文本", text: Binding(
                get: { entry.text },
                set: { newText in
                    vm.updateSubtitleEntry(resultID: resultID, entryIndex: index, text: newText)
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))

            if let translated = entry.translatedText {
                TextField("翻译文本", text: Binding(
                    get: { translated },
                    set: { newText in
                        vm.updateTranslatedText(resultID: resultID, entryIndex: index, text: newText)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: 纯文本预览

    private var fullTextPreviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("识别全文")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            ForEach(viewModel.results) { result in
                if let fullText = result.fullText, !fullText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(result.originalURL.lastPathComponent)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textSecondary)

                        Text(fullText)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(AppColors.cardBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color(white: 0.88), lineWidth: 1)
                            )

                        if let tft = result.translatedFullText, !tft.isEmpty {
                            Text("译文")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColors.textSecondary)
                                .padding(.top, 8)

                            Text(tft)
                                .font(.system(size: 14))
                                .foregroundColor(AppColors.primary)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(AppColors.primary.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(AppColors.primary.opacity(0.2), lineWidth: 1)
                                )
                        }

                        Button("导出纯文本") {
                            viewModel.reExportSubtitles(resultID: result.id)
                        }
                        .buttonStyle(.bordered)
                        .tint(AppColors.primary)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppColors.cardBackground)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color(white: 0.88), lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: 隐私声明

    private var privacyNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 14))
                .foregroundColor(.green)
            Text("所有文件全程本地离线处理，不上传任何数据到云端")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.green.opacity(0.06))
        )
    }

    // MARK: 辅助

    private func formatDuration(_ t: TimeInterval) -> String {
        guard t.isFinite && t >= 0 else { return "00:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

#endif
