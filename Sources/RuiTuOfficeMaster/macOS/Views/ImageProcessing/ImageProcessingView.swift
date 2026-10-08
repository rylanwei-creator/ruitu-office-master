#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 图片压缩与尺寸调整页面

struct ImageProcessingView: View {
    @State private var viewModel = ImageCompressionViewModel()

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
                        Text("图片压缩与尺寸调整")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    Text("批量调整图片尺寸与格式；压缩效果取决于图片内容及所选参数")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.top, 24)

                // 子功能介绍
                featureIntroSection

                // 第一步：选择图片
                imageSelectionSection
                    .disabled(viewModel.isProcessing)

                // 压缩设置
                if !viewModel.selectedImages.isEmpty {
                    compressionConfigSection
                        .disabled(viewModel.isProcessing)

                    // 格式转换
                    formatConversionSection
                        .disabled(viewModel.isProcessing)

                    // 执行
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
                icon: "shippingbox",
                title: "体积压缩",
                desc: "调节有损格式的质量；PNG 保留颜色层次，缩小尺寸可减小体积"
            )
            .frame(maxHeight: .infinity)
            FeatureIntroItem(
                icon: "arrow.up.left.and.down.right.magnifyingglass",
                title: "尺寸调整",
                desc: "自由修改宽高、等比缩放、适配各类平台标准尺寸"
            )
            .frame(maxHeight: .infinity)
            FeatureIntroItem(
                icon: "arrow.triangle.swap",
                title: "格式转换",
                desc: "按本机支持的编码格式输出；转换为 JPG 时透明区域填充白色"
            )
            .frame(maxHeight: .infinity)
            FeatureIntroItem(
                icon: "square.grid.3x3.topleft.filled",
                title: "批量处理",
                desc: "逐张处理并显示成功与失败结果"
            )
            .frame(maxHeight: .infinity)
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
                    Button(action: { viewModel.selectImages() }) {
                        Label("选择图片", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    if !viewModel.selectedImages.isEmpty {
                        Button(action: { viewModel = ImageCompressionViewModel() }) {
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
                handleImageDrop(providers: providers)
                return true
            }

            // 已选文件列表（可删除单张 + 调整顺序）
            if !viewModel.selectedImages.isEmpty {
                imageFileList
            }
        }
    }

    // MARK: - 已选图片列表

    private var imageFileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 列表头
            HStack {
                Text(viewModel.imageCountText)
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

            // 文件行
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

                        Text(FileUtils.formatSize(viewModel.originalSizes[url] ?? 0))
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                            .frame(width: 70, alignment: .trailing)

                        Button(action: { removeImageSafely(url: url) }) {
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

    // MARK: - 压缩配置

    private var compressionConfigSection: some View {
        @Bindable var vm = viewModel

        return VStack(alignment: .leading, spacing: 12) {
            Text("2. 压缩设置")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: 20) {
                // 压缩档位
                VStack(alignment: .leading, spacing: 8) {
                    Text("压缩档位")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 0) {
                        ForEach(CompressionLevel.allCases, id: \.self) { level in
                            CompressionLevelButton(
                                level: level,
                                isSelected: vm.compressionLevel == level
                            ) {
                                viewModel.selectCompressionLevel(level)
                            }
                        }
                    }
                }

                // 自定义质量滑块（仅自定义模式）
                if vm.showCustomSlider {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("自定义质量")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text("\(vm.qualityPercent)%")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(AppColors.primary)
                        }

                        Slider(value: $vm.quality, in: 0.05...1.0, step: 0.05)
                            .tint(AppColors.primary)
                            .onChange(of: vm.quality) {
                                viewModel.refreshEstimates()
                            }

                        HStack {
                            Text("最小体积")
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text("最佳质量")
                                .font(.system(size: 11))
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                }

                Divider()
                    .foregroundColor(AppColors.textSecondary.opacity(0.15))

                // 尺寸模式
                VStack(alignment: .leading, spacing: 8) {
                    Text("尺寸模式")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(AppColors.textPrimary)

                    Picker("", selection: $vm.sizeMode) {
                        ForEach(SizeMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)

                    // 尺寸参数（按模式不同）
                    sizeModeParameters
                }

                // 预估信息
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("原始大小")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                        Text(vm.originalTotalSizeText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("预估大小（按当前设置编码）")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                        Text(vm.estimatedSizeText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(vm.estimatedChangeColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("预估体积变化")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                        Text(vm.estimatedChangeText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(vm.estimatedChangeColor)
                    }
                }

                // 小文件提示
                if let note = vm.smallFileNote {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#FF9500"))
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#FF9500"))
                    }
                }

                Text("档位预期：\(vm.compressionLevel.expectedReduction)，实际效果取决于图片内容复杂度")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary.opacity(0.7))
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.cardBackground)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        }
    }

    // MARK: - 尺寸模式参数

    @ViewBuilder
    private var sizeModeParameters: some View {
        @Bindable var vm = viewModel

        switch vm.sizeMode {
        case .aspectRatio:
            HStack(spacing: 16) {
                Image(systemName: "lock.rectangle")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("宽度 (px)")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("宽度", text: $vm.aspectWidth)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                        .onChange(of: vm.aspectWidth) {
                            viewModel.syncHeightFromWidth()
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("高度 (px)")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("高度", text: $vm.aspectHeight)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                        .onChange(of: vm.aspectHeight) {
                            viewModel.syncWidthFromHeight()
                        }
                }
                Text("每张图片等比缩小到宽高框内，不放大、不拉伸")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary.opacity(0.7))
                    .padding(.leading, 8)
            }
            .padding(.top, 4)

        case .custom:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("宽度 (px)")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("1920", text: $vm.customWidth)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                        .onChange(of: vm.customWidth) {
                            viewModel.refreshEstimates()
                        }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("高度 (px)")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary)
                    TextField("1080", text: $vm.customHeight)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                        .onChange(of: vm.customHeight) {
                            viewModel.refreshEstimates()
                        }
                }
                Text("仅调整尺寸，不保证纵横比")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.leading, 8)
            }
            .padding(.top, 4)

        case .maxDimension:
            HStack(spacing: 12) {
                Text("最大边长")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                Picker("", selection: $vm.maxDimension) {
                    Text("1024 px").tag(CGFloat(1024))
                    Text("2048 px").tag(CGFloat(2048))
                    Text("4096 px").tag(CGFloat(4096))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
                .onChange(of: vm.maxDimension) {
                    viewModel.refreshEstimates()
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 格式转换

    private var formatConversionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("3. 格式转换")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: 16) {
                // 格式选择按钮组
                HStack(spacing: 8) {
                    ForEach(OutputFormat.available, id: \.rawValue) { format in
                        Button(action: { viewModel.outputFormat = format }) {
                            Text(format.rawValue)
                                .font(.system(size: 13, weight: viewModel.outputFormat == format ? .semibold : .medium))
                                .foregroundColor(viewModel.outputFormat == format ? .white : AppColors.textPrimary)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .frame(minWidth: 90)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(viewModel.outputFormat == format ? AppColors.primary : AppColors.primaryLight)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 辅助说明
                Text("一键批量转换图片格式，适配不同平台、设备、上传要求")
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textSecondary)
            }
            .onChange(of: viewModel.outputFormat) {
                viewModel.refreshEstimates()
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
                    progress: Binding(
                        get: { viewModel.progress },
                        set: { _ in }
                    ),
                    currentFile: viewModel.currentFileName
                )
            }

            HStack(spacing: 12) {
                Button(action: { viewModel.executeCompression() }) {
                    Label("开始批量处理", systemImage: "arrow.triangle.capsulepath")
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

            if let message = viewModel.validationMessage {
                Label(message, systemImage: "info.circle").font(.system(size: 12)).foregroundColor(AppColors.error)
            }
            if viewModel.isProcessing {
                Button("停止后续图片", action: { viewModel.cancelProcessing() }).buttonStyle(.bordered)
            }
            // 大文件警告
            if let warning = viewModel.largeFileWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }
        }
    }

    // MARK: - 压缩结果

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("压缩结果")
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
                    Text("原始大小")
                        .frame(width: 80, alignment: .trailing)
                    Text("压缩后")
                        .frame(width: 80, alignment: .trailing)
                    Text("体积变化")
                        .frame(width: 95, alignment: .trailing)
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

    private func resultRow(_ result: CompressionResult) -> some View {
        HStack {
            Text(result.originalURL.lastPathComponent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(AppColors.textPrimary)

            Text(FileUtils.formatSize(result.originalSize))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(AppColors.textSecondary)

            Text(FileUtils.formatSize(result.compressedSize))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(AppColors.primary)

            Text(result.changeText)
                .frame(width: 95, alignment: .trailing)
                .foregroundColor(result.savedPercent >= 0 ? AppColors.success : AppColors.textSecondary)
                .fontWeight(.medium)
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

    private func handleImageDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async {
                        viewModel.addImages(from: [url])
                    }
                }
            }
        }
    }
    // MARK: - 安全移除图片

    /// 移除单张图片：当只剩一张时替换整个 ViewModel（原子操作），避免多个条件区块同时消失导致布局死锁
    private func removeImageSafely(url: URL) { viewModel.removeImage(url: url) }
}

// MARK: - 子功能介绍项

// MARK: - 压缩档位按钮

private struct CompressionLevelButton: View {
    let level: CompressionLevel
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
        VStack(spacing: 2) {
            Text(level.rawValue)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            if !level.description.isEmpty {
                Text(level.description)
                    .font(.system(size: 10))
                    .opacity(0.7)
            }
        }
        .foregroundColor(isSelected ? .white : AppColors.textPrimary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? AppColors.primary : AppColors.primaryLight)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(level.rawValue + "，" + level.description)
    }
}

#endif
