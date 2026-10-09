#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

#if canImport(Translation)
import Translation
#endif

// MARK: - OCR 文字识别页面

struct OCRView: View {
    @State private var viewModel = OCRViewModel()
    @State private var previewResult: OCRImageResult?

    var body: some View {
        VStack(spacing: 0) {
            let scrollContent = ScrollView {
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
                            Text("OCR 文字识别")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundColor(AppColors.textPrimary)
                        }
                        Text("从图片或 PDF 中提取文字，支持印刷体与手写体，纯本地离线识别")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .padding(.top, 24)

                    // 子功能介绍
                    featureIntroSection

                    // 导入模式选择
                    importModeSection
                    .disabled(viewModel.isProcessing)

                    // 文件选择
                    fileSelectionSection
                    .disabled(viewModel.isProcessing)

                    // 设置 + 执行
                    if viewModel.canExecute || viewModel.isProcessing {
                        settingsSection
                        executeSection
                    }

                    // 识别结果
                    if viewModel.hasResult {
                        resultSection
                    }

                    // 翻译结果
                    if viewModel.hasTranslation {
                        translationResultSection
                    }
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 900)
            }

            // 翻译桥接：注入 TranslationSession 到 ViewModel（macOS 15.0+）
            if #available(macOS 15.0, *) {
                scrollContent
                    .translationTask(source: nil, target: nil) { session in
                        viewModel.setTranslationSession(session)
                    }
            } else {
                scrollContent
            }

            privacyNotice
                .padding(.bottom, 8)
        }
        .background(AppColors.background)
        .sheet(item: $previewResult) { result in
            OCRSourcePreview(url: result.sourceURL)
        }
    }

    // MARK: - 子功能介绍

    private var featureIntroSection: some View {
        HStack(spacing: 16) {
            FeatureIntroItem(
                icon: "text.viewfinder",
                title: "精准识别",
                desc: "基于 Apple Vision 框架，支持中英文印刷体与手写体文字识别"
            )
            FeatureIntroItem(
                icon: "doc.richtext",
                title: "多格式导入",
                desc: "支持单张/批量图片、PDF 文档导入，逐页识别自动汇总"
            )
            FeatureIntroItem(
                icon: "sparkles",
                title: "智能增强",
                desc: "可选提亮与对比度调整，识别效果取决于原图清晰度"
            )
            FeatureIntroItem(
                icon: "globe",
                title: "一键翻译",
                desc: "识别结果一键翻译为英文/中文，留学、外文文档利器"
            )
        }
    }

    // MARK: - 导入模式选择

    private var importModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导入方式")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary)

            HStack(spacing: 0) {
                ForEach(OCRImportMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue)
                        .font(.system(size: 13, weight: viewModel.importMode == mode ? .semibold : .medium))
                        .foregroundColor(viewModel.importMode == mode ? .white : AppColors.textPrimary)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(
                            viewModel.importMode == mode ? AppColors.primary : AppColors.primaryLight
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.switchImportMode(to: mode) }
                }
            }
            .cornerRadius(7)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(AppColors.primaryLight, lineWidth: 1)
            )
        }
    }

    // MARK: - 文件选择区域

    private var fileSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择文件")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            switch viewModel.importMode {
            case .singleImage:
                singleImagePicker
            case .batchImages:
                batchImagePicker
            case .pdf:
                pdfPicker
            }
        }
    }

    // MARK: 单张图片选择器

    private var singleImagePicker: some View {
        Group {
            if let preview = viewModel.previewImage {
                VStack(spacing: 12) {
                    preview
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 400, maxHeight: 300)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.primary)
                        Text(viewModel.selectedImage?.lastPathComponent ?? "")
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textPrimary)
                        Text(viewModel.totalSizeText)
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary)
                        Spacer()
                        Button(action: { viewModel.selectFiles() }) {
                            Label("更换", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        Button(action: { viewModel.clearAll() }) {
                            Label("清空", systemImage: "trash")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(AppColors.cardBackground)
                    .cornerRadius(8)
                }
            } else {
                dropZone(
                    icon: "text.viewfinder",
                    text: "拖拽图片到此处，或点击下方按钮选择",
                    hint: "支持 JPG、PNG、HEIC、WebP、BMP、TIFF 格式"
                )
            }
        }
    }

    // MARK: 批量图片选择器

    private var batchImagePicker: some View {
        VStack(spacing: 12) {
            if !viewModel.selectedImages.isEmpty {
                VStack(spacing: 0) {
                    HStack {
                        Text(viewModel.fileCountText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                        Spacer()
                        Text("总大小: \(viewModel.totalSizeText)")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(AppColors.primaryLight.opacity(0.35))

                    VStack(spacing: 0) {
                        ForEach(viewModel.selectedImages, id: \.self) { url in
                            HStack(spacing: 8) {
                                Image(systemName: "photo")
                                    .font(.system(size: 14))
                                    .foregroundColor(AppColors.primary)
                                Text(url.lastPathComponent)
                                    .font(.system(size: 13))
                                    .foregroundColor(AppColors.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                Text(FileUtils.formatSize(viewModel.fileSizes[url] ?? 0))
                                    .font(.system(size: 11))
                                    .foregroundColor(AppColors.textSecondary)
                                Button(action: { viewModel.removeFile(url: url) }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(AppColors.textSecondary.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            if url != viewModel.selectedImages.last {
                                Divider()
                            }
                        }
                    }
                }
                .background(AppColors.cardBackground)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.gray.opacity(0.15), lineWidth: 1)
                )
            }

            HStack(spacing: 12) {
                Button(action: { viewModel.selectFiles() }) {
                    Label("添加图片", systemImage: "plus")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)

                if !viewModel.selectedImages.isEmpty {
                    Button(action: { viewModel.clearAll() }) {
                        Label("清空列表", systemImage: "trash")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    // MARK: PDF 选择器

    private var pdfPicker: some View {
        Group {
            if let pdfURL = viewModel.selectedPDF {
                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.primary)
                        Text(pdfURL.lastPathComponent)
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textPrimary)
                        Text(viewModel.totalSizeText)
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textSecondary)
                        Spacer()
                        Button(action: { viewModel.selectFiles() }) {
                            Label("更换", systemImage: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                        Button(action: { viewModel.clearAll() }) {
                            Label("清空", systemImage: "trash")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(AppColors.cardBackground)
                    .cornerRadius(8)
                }
            } else {
                dropZone(
                    icon: "doc.richtext",
                    text: "拖拽 PDF 到此处，或点击下方按钮选择",
                    hint: "支持普通 PDF 和扫描版 PDF，自动分页识别"
                )
            }
        }
    }

    // MARK: - 通用拖拽区域

    private func dropZone(icon: String, text: String, hint: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 32))
                .foregroundColor(AppColors.textSecondary.opacity(0.5))

            Text(text)
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)

            Text(hint)
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary.opacity(0.6))

            Button(action: { viewModel.selectFiles() }) {
                Label("选择文件", systemImage: "folder")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.bordered)
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

    // MARK: - 识别设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. 识别设置")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: 16) {
                // 语言
                VStack(alignment: .leading, spacing: 6) {
                    Text("识别语言")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)

                    HStack(spacing: 8) {
                        ForEach(["auto", "en-US"], id: \.self) { code in
                            let name: String = code == "auto"
                                ? "自动识别"
                                : (OCRService.supportedLanguages.first(where: { $0.code == code })?.name ?? code)
                            let isSelected = viewModel.selectedLanguages.contains(code)
                            Text(name)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                                .foregroundColor(isSelected ? .white : AppColors.textPrimary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 6)
                                .frame(minWidth: 80)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(isSelected ? AppColors.primary : AppColors.primaryLight)
                                )
                                .contentShape(RoundedRectangle(cornerRadius: 6))
                                .onTapGesture {
                                    viewModel.selectedLanguages = [code]
                                }
                        }
                    }
                }

                // 图片增强开关
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("图片智能增强")
                            .font(.system(size: 12))
                            .foregroundColor(AppColors.textPrimary)
                        Text("自动提亮、增强对比度，改善模糊/暗光照片识别效果")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: $viewModel.enablePreprocess)
                        .toggleStyle(.switch)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
    }

    // MARK: - 执行区域

    private var executeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.isProcessing {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressBar(
                        progress: Binding(get: { viewModel.progress }, set: { _ in }),
                        currentFile: viewModel.currentFileName
                    )
                    if !viewModel.progressDetail.isEmpty {
                        Text(viewModel.progressDetail)
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
            }

            HStack(spacing: 12) {
                Button(action: { viewModel.executeRecognition() }) {
                    Label("开始识别", systemImage: "text.viewfinder")
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canExecute)

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

    // MARK: - 识别结果

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("识别结果")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()

                HStack(spacing: 8) {
                    Button(action: { viewModel.reformatText() }) {
                        Label("规整排版", systemImage: "text.alignleft")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)

                    Button(action: { viewModel.copyAllText() }) {
                        Label(viewModel.imageResults.isEmpty ? "一键复制" : "复制全部", systemImage: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)

                    if viewModel.imageResults.isEmpty {
                        Button(action: {
                            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
                        }) {
                            Label("全选文本", systemImage: "text.cursor")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(action: { viewModel.exportAsWord() }) {
                        Label("导出 RTF 文档", systemImage: "doc.badge.gearshape")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)

                    if viewModel.imageResults.isEmpty {
                        Button(action: { viewModel.saveAsText() }) {
                            Label("保存 TXT", systemImage: "square.and.arrow.down")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Menu {
                            Button("合并为一个 TXT") { viewModel.saveAsText() }
                            Button("每张图片单独一个 TXT…") { viewModel.saveSeparateTexts() }
                                .disabled(viewModel.isExportingTexts || !viewModel.hasText)
                        } label: {
                            Label(viewModel.isExportingTexts ? "正在导出…" : "导出 TXT", systemImage: "square.and.arrow.down")
                                .font(.system(size: 12))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }

                    Button(action: { viewModel.triggerTranslation() }) {
                        Label(
                            viewModel.isTranslating ? "翻译中..." : (viewModel.imageResults.isEmpty ? "一键翻译" : "翻译全部"),
                            systemImage: "globe"
                        )
                        .font(.system(size: 12))
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isTranslating || !viewModel.hasText)
                }
            }

            if viewModel.imageResults.isEmpty {
                TextEditor(text: $viewModel.recognizedText)
                    .font(.system(size: 14))
                    .frame(minHeight: 300)
                    .padding(12)
                    .background(AppColors.cardBackground)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                    .overlay(alignment: .topLeading) {
                        if viewModel.recognizedText.isEmpty {
                            Text("识别结果将显示在这里...")
                                .font(.system(size: 13))
                                .foregroundColor(AppColors.textSecondary.opacity(0.5))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 20)
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                Text("点击缩略图可放大原图；每张图片可分别编辑和保存，也可合并或分别导出 TXT。")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                ForEach(Array(viewModel.imageResults.enumerated()), id: \.element.id) { index, result in
                    imageResultCard(result, index: index)
                }
            }
        }
    }

    private func imageResultCard(_ result: OCRImageResult, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                OCRSourceThumbnail(url: result.sourceURL) { previewResult = result }
                VStack(alignment: .leading, spacing: 4) {
                    Text("图片 \(index + 1)")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                    Text(result.fileName)
                        .font(.system(size: 14, weight: .semibold))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(result.sourceURL.path)
                }
                Spacer(minLength: 12)
                Button { viewModel.copyText(result.text) } label: {
                    Label("复制文字", systemImage: "doc.on.doc")
                }
                .disabled(!result.hasText)
                Button { viewModel.saveAsText(resultID: result.id) } label: {
                    Label("保存 TXT", systemImage: "square.and.arrow.down")
                }
                .disabled(!result.hasText)
            }
            .buttonStyle(.bordered)
            .font(.system(size: 12))

            if !result.hasText, let notice = result.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
            }
            OCRAdaptiveTextEditor(text: Binding(
                get: { viewModel.imageResults.first(where: { $0.id == result.id })?.text ?? "" },
                set: { viewModel.setImageText(id: result.id, text: $0) }
            ), label: "\(result.fileName) 的识别文字")

            if !result.translatedText.isEmpty {
                Divider()
                HStack {
                    Text("译文 · \(result.fileName)")
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button { viewModel.copyText(result.translatedText) } label: {
                        Label("复制译文", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                }
                OCRAdaptiveTextEditor(text: Binding(
                    get: { viewModel.imageResults.first(where: { $0.id == result.id })?.translatedText ?? "" },
                    set: { viewModel.setImageTranslation(id: result.id, text: $0) }
                ), label: "\(result.fileName) 的译文")
            }
        }
        .padding(16)
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gray.opacity(0.2), lineWidth: 1))
    }

    // MARK: - 翻译结果

    private var translationResultSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("翻译结果")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(viewModel.translatedText, forType: .string)
                }) {
                    Label("复制译文", systemImage: "doc.on.doc")
                        .font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }

            TextEditor(text: $viewModel.translatedText)
                .font(.system(size: 14))
                .frame(minHeight: 200)
                .padding(12)
                .background(AppColors.cardBackground)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
        }
    }

    // MARK: - 隐私声明

    private var privacyNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 12))
                .foregroundColor(AppColors.success)
            Text("文字识别在本机进行，不上传文件；翻译语言包可能需要联网下载")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 12)
    }

    // MARK: - 拖拽处理

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        viewModel.addFile(from: url)
                    }
                }
            }
        }
    }
}

#endif
