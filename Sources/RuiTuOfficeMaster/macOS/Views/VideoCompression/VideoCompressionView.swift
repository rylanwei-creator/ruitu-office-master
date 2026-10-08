#if os(macOS)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 视频压缩页面

struct VideoCompressionView: View {
    @State private var viewModel = VideoCompressionViewModel()
    @State private var previewItem: VideoCompressionItem?

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
                        Text("视频压缩")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    Text("压缩视频文件大小，调节画质与分辨率，适配各种平台和设备的体积要求")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.top, 24)

                // 子功能介绍
                featureIntroSection

                // 第一步：选择视频
                videoSelectionSection
                    .disabled(viewModel.isProcessing)

                // 设置 + 执行
                if !viewModel.selectedVideos.isEmpty {
                    compressionConfigSection
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
    .sheet(item: $previewItem) { item in
        VideoResultPreview(url: item.compressedURL)
    }
    }

    // MARK: - 子功能介绍

    private var featureIntroSection: some View {
        HStack(spacing: 16) {
            FeatureIntroItem(
                icon: "shippingbox",
                title: "体积压缩",
                desc: "按所选质量与分辨率重新编码；画质和体积可能发生变化"
            )
            FeatureIntroItem(
                icon: "arrow.up.left.and.down.right.magnifyingglass",
                title: "分辨率调节",
                desc: "支持 4K/1080p/720p/480p 多档分辨率，自由适配各平台需求"
            )
            FeatureIntroItem(
                icon: "arrow.triangle.swap",
                title: "格式转换",
                desc: "输出 MP4 或 MOV，兼容性取决于编码和播放设备"
            )
            FeatureIntroItem(
                icon: "square.grid.3x3.topleft.filled",
                title: "批量处理",
                desc: "多视频一次性批量压缩，省去逐个操作的繁琐"
            )
        }
    }

    // MARK: - 视频选择区域

    private var videoSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("1. 选择视频")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.system(size: 32))
                    .foregroundColor(AppColors.textSecondary.opacity(0.5))

                Text("拖拽视频到此处，或点击下方按钮选择")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)

                HStack(spacing: 12) {
                    Button(action: { viewModel.selectVideos() }) {
                        Label("选择视频", systemImage: "folder")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    if !viewModel.selectedVideos.isEmpty {
                        Button(action: { viewModel = VideoCompressionViewModel() }) {
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

            // 已选视频列表
            if !viewModel.selectedVideos.isEmpty {
                videoFileList
            }
        }
    }

    // MARK: - 已选视频列表（含单条预估）

    private var videoFileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部标题栏
            HStack {
                Text(viewModel.videoCountText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                Text("拖拽或点击按钮可继续添加")
                    .font(.system(size: 10))
                    .foregroundColor(AppColors.textSecondary.opacity(0.5))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppColors.primaryLight.opacity(0.35))

            // 列表头
            HStack(spacing: 0) {
                Text("文件名")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("原始")
                    .frame(width: 72, alignment: .trailing)
                Text("预估压缩后")
                    .frame(width: 80, alignment: .trailing)
                Text("体积变化")
                    .frame(width: 52, alignment: .trailing)
                Color.clear.frame(width: 22)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(AppColors.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AppColors.background.opacity(0.6))

            Divider().foregroundColor(AppColors.textSecondary.opacity(0.15))

            // 视频行
            VStack(spacing: 0) {
                ForEach(viewModel.selectedVideos, id: \.self) { url in
                    videoFileRow(url)
                    if url != viewModel.selectedVideos.last {
                        Divider()
                            .foregroundColor(AppColors.textSecondary.opacity(0.1))
                            .padding(.leading, 12)
                    }
                }
            }

            Divider().foregroundColor(AppColors.textSecondary.opacity(0.15))

            // 底部合计行
            HStack(spacing: 0) {
                Text("合计 \(viewModel.selectedVideos.count) 个文件")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(viewModel.originalTotalSizeText)
                    .frame(width: 72, alignment: .trailing)

                Text(viewModel.estimatedSizeText)
                    .frame(width: 80, alignment: .trailing)

                Text(viewModel.estimatedChangeText)
                    .frame(width: 52, alignment: .trailing)

                Color.clear.frame(width: 22)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(AppColors.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppColors.success.opacity(0.06))
        }
        .background(AppColors.cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.15), lineWidth: 1)
        )
    }

    /// 单行：文件名 | 原始大小 | 预估压缩后 | 节省% | 移除
    private func videoFileRow(_ url: URL) -> some View {
        let origSize = viewModel.originalSizes[url] ?? 0
        let estPct = viewModel.estimatedSavedPercent(for: url)
        let pctColor: Color = estPct >= 20 ? AppColors.success : Color(hex: "#FF9500")

        return HStack(spacing: 0) {
            Image(systemName: "film")
                .font(.system(size: 12))
                .foregroundColor(AppColors.primary)
                .frame(width: 16)

            Text(url.lastPathComponent)
                .font(.system(size: 12))
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(FileUtils.formatSize(origSize))
                .font(.system(size: 11))
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 72, alignment: .trailing)

            Text(viewModel.estimatedSizeText(for: url))
                .font(.system(size: 11))
                .foregroundColor(origSize > 0 ? AppColors.success : AppColors.textSecondary)
                .frame(width: 80, alignment: .trailing)

            Text(viewModel.estimatedSizes[url] == nil ? "待估算" : (estPct >= 0 ? "−\(estPct)%" : "+\(-estPct)%"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(pctColor)
                .frame(width: 52, alignment: .trailing)

            Button(action: { removeVideoSafely(url: url) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .frame(width: 22)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: - 压缩配置

    private var compressionConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. 压缩设置")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)

            VStack(alignment: .leading, spacing: 20) {
                // 画质
                VStack(alignment: .leading, spacing: 8) {
                    Text("画质")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)

                    HStack(spacing: 0) {
                        ForEach(VideoQuality.allCases, id: \.self) { q in
                            Button {
                                viewModel.quality = q
                                viewModel.refreshEstimates()
                            } label: {
                            Text(q.rawValue)
                                .font(.system(size: 13, weight: viewModel.quality == q ? .semibold : .medium))
                                .foregroundColor(viewModel.quality == q ? .white : AppColors.textPrimary)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 8)
                                .background(
                                    viewModel.quality == q ? AppColors.primary : AppColors.primaryLight
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .cornerRadius(7)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(AppColors.primaryLight, lineWidth: 1)
                    )
                }

                // 分辨率
                VStack(alignment: .leading, spacing: 8) {
                    Text("分辨率")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)

                    Picker("", selection: $viewModel.resolution) {
                        ForEach(VideoResolution.allCases, id: \.self) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 260)
                    .onChange(of: viewModel.resolution) {
                        viewModel.refreshEstimates()
                    }

                    Text("建议保持「原始分辨率」以避免画质损失，仅在确实需要降低分辨率时切换")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary.opacity(0.7))
                }

                // 输出格式
                VStack(alignment: .leading, spacing: 8) {
                    Text("输出格式与编码器")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textSecondary)

                    HStack(spacing: 16) {
                        Picker("", selection: $viewModel.outputFormat) {
                            ForEach(VideoOutputFormat.allCases, id: \.self) { fmt in
                                Text(fmt.rawValue).tag(fmt)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 100)

                        Picker("", selection: $viewModel.codec) {
                            ForEach(VideoCodec.allCases, id: \.self) { codec in
                                Text(codec.rawValue).tag(codec)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 170)
                        .onChange(of: viewModel.codec) {
                            viewModel.refreshEstimates()
                        }
                    }

                    Text("H.264 兼容性较好；H.265（HEVC）通常有更高压缩效率，部分老旧播放器可能不兼容")
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textSecondary.opacity(0.7))
                }

                Divider()
                    .foregroundColor(AppColors.textSecondary.opacity(0.15))

                // 预估信息
                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("原始大小")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                        Text(viewModel.originalTotalSizeText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("预估压缩后（仅供参考）")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                        Text(viewModel.estimatedSizeText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(AppColors.success)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("预估体积变化")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textSecondary)
                        Text(viewModel.estimatedChangeText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppColors.success)
                    }
                }

                // 小文件提示
                if let note = viewModel.smallFileNote {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#FF9500"))
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#FF9500"))
                    }
                }

                Text("不保证固定缩减比例，实际效果取决于源文件、质量、分辨率和编码格式")
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
                Button(action: { viewModel.executeCompression() }) {
                    Label("开始批量压缩", systemImage: "arrow.triangle.capsulepath")
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
                        videoResultRow(result)
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

    private func videoResultRow(_ item: VideoCompressionItem) -> some View {
        HStack {
            Button {
                previewItem = item
            } label: {
                Image(systemName: "play.circle").foregroundColor(AppColors.primary)
            }
            .buttonStyle(.plain)
            .help("预览处理结果")
            .accessibilityLabel("预览 " + item.originalURL.lastPathComponent)
            Text(item.originalURL.lastPathComponent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(AppColors.textPrimary)

            Text(FileUtils.formatSize(item.originalSize))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(AppColors.textSecondary)

            Text(FileUtils.formatSize(item.compressedSize))
                .frame(width: 80, alignment: .trailing)
                .foregroundColor(AppColors.primary)

            Text(item.changeText)
                .frame(width: 95, alignment: .trailing)
                .foregroundColor(AppColors.success)
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
            Text("视频在本机处理，不上传到服务器")
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
                        viewModel.addVideos(from: [url])
                    }
                }
            }
        }
    }

    // MARK: - 安全移除

    private func removeVideoSafely(url: URL) {
        if viewModel.selectedVideos.count == 1 {
            viewModel = VideoCompressionViewModel()
        } else {
            viewModel.removeVideo(url: url)
        }
    }
}

#endif
