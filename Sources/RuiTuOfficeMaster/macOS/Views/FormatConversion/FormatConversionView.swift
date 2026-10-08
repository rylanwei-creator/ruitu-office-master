#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 图片格式转换页面

struct FormatConversionView: View {
    @State private var viewModel = FormatConversionViewModel()

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
                        Text("图片格式转换")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    Text("批量转换图片格式；输出选项按本机能力提供，JPG 使用有损编码")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.top, 24)

                // 子功能介绍
                featureIntroSection

                // 第一步：选择图片
                imageSelectionSection
                    .disabled(viewModel.isProcessing)

                // 设置 + 执行
                if !viewModel.selectedFiles.isEmpty {
                    conversionConfigSection
                    .disabled(viewModel.isProcessing)
                    executeSection

                    // 结果显示
                    if !viewModel.results.isEmpty {
                        resultsSection
                    }
                }

            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 900)
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
                icon: "arrow.triangle.swap",
                title: "格式互转",
                desc: "任意格式之间互相转换，满足不同平台和设备的格式需求"
            )
            FeatureIntroItem(
                icon: "photo.stack",
                title: "多种格式",
                desc: "支持读取常见图片；可用输出格式以选择器为准"
            )
            FeatureIntroItem(
                icon: "scalemass",
                title: "画质说明",
                desc: "JPG、HEIC 为有损格式；PNG 保留透明区域，JPG 使用白色背景"
            )
            FeatureIntroItem(
                icon: "square.grid.3x3.topleft.filled",
                title: "批量处理",
                desc: "海量图片一次性批量转换，效率直接翻倍"
            )
        }
    }

    // MARK: - 图片选择区域

    private var imageSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择图片")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 32))
                    .foregroundColor(AppColors.textSecondary.opacity(0.5))

                Text("拖拽图片到此处，或点击下方按钮选择")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)

                HStack(spacing: 12) {
                    Button(action: { viewModel.selectFiles() }) {
                        Label("选择图片", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    if !viewModel.selectedFiles.isEmpty {
                        Button(action: { viewModel = FormatConversionViewModel() }) {
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

            // 已选文件列表
            if !viewModel.selectedFiles.isEmpty {
                fileListSection
            }
        }
    }

    // MARK: - 已选文件列表

    private var fileListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(viewModel.fileCountText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Text("原始总大小: \(viewModel.originalTotalSizeText)")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppColors.primaryLight.opacity(0.35))

            VStack(spacing: 0) {
                ForEach(viewModel.selectedFiles, id: \.self) { url in
                    HStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.primary)

                        Text(url.lastPathComponent)
                            .font(.system(size: 13))
                            .foregroundColor(AppColors.textPrimary)
                            .lineLimit(1)

                        Spacer()

                        Text(FileUtils.formatSize(viewModel.originalSizes[url] ?? 0))
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                            .frame(width: 70, alignment: .trailing)

                        Button(action: { removeFileSafely(url: url) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(AppColors.textSecondary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)

                    if url != viewModel.selectedFiles.last {
                        Divider()
                            .foregroundColor(AppColors.textSecondary.opacity(0.15))
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

    // MARK: - 转换配置

    private var conversionConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. 转换设置")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: 12) {
                Text("目标格式")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)

                HStack(spacing: 12) {
                    ForEach(ConversionFormat.available, id: \.self) { format in
                        FormatButton(
                            format: format,
                            isSelected: viewModel.targetFormat == format
                        ) {
                            viewModel.targetFormat = format
                            viewModel.results = []
                        }
                    }
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
                ProgressBar(
                    progress: Binding(get: { viewModel.progress }, set: { _ in }),
                    currentFile: viewModel.currentFileName
                )
            }

            HStack(spacing: 12) {
                Button(action: { viewModel.executeConversion() }) {
                    Label("开始批量转换", systemImage: "arrow.triangle.capsulepath")
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

    // MARK: - 转换结果

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("转换结果")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Button(action: { viewModel.saveResults() }) {
                    Label("保存到...", systemImage: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .medium))
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: 0) {
                HStack {
                    Text("文件名")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("目标格式")
                        .frame(width: 70, alignment: .leading)
                    Text("原始大小")
                        .frame(width: 80, alignment: .trailing)
                    Text("转换后")
                        .frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AppColors.textSecondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppColors.primaryLight.opacity(0.5))

                VStack(spacing: 0) {
                    ForEach(viewModel.results, id: \.originalURL) { result in
                        resultRow(result)
                        if result.originalURL != viewModel.results.last?.originalURL {
                            Divider()
                                .foregroundColor(AppColors.textSecondary.opacity(0.15))
                        }
                    }
                }
            }
            .background(AppColors.cardBackground)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.gray.opacity(0.2), lineWidth: 1)
            )
        }
    }

    private func resultRow(_ item: ConversionResultItem) -> some View {
        HStack {
            Text(item.originalURL.lastPathComponent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(AppColors.textPrimary)

            Text(item.targetFormat.rawValue)
                .frame(width: 70, alignment: .leading)
                .foregroundColor(AppColors.primary)

            Text(FileUtils.formatSize(item.originalSize))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(AppColors.textSecondary)

            Text(FileUtils.formatSize(item.convertedSize))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(AppColors.primary)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - 隐私声明

    private var privacyNotice: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 12))
                .foregroundColor(AppColors.success)
            Text("图片在本机处理，不上传到服务器")
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
                        viewModel.addFiles(from: [url])
                    }
                }
            }
        }
    }

    // MARK: - 安全移除

    private func removeFileSafely(url: URL) {
        if viewModel.selectedFiles.count == 1 {
            viewModel = FormatConversionViewModel()
        } else {
            viewModel.removeFile(url: url)
        }
    }
}

// MARK: - 格式按钮

private struct FormatButton: View {
    let format: ConversionFormat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Text(format.rawValue)
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundColor(isSelected ? .white : AppColors.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? AppColors.primary : AppColors.primaryLight)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { action() }
    }
}

#endif
