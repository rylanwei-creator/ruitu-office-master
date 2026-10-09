#if os(macOS)
import SwiftUI
import AppKit

/// 复用带 EXIF 方向校正的有界解码，不在主线程读取整张原图。
enum OCRPreviewLoader {
    static func load(_ url: URL, maxDimension: CGFloat) async throws -> CGImage {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let dimensions = try ImageCodec.dimensions(at: url)
            let size = try ImageCodec.outputSize(original: dimensions, maxDimension: maxDimension, targetSize: nil, fitWithin: nil)
            let image = try ImageCodec.load(at: url, size: size)
            try Task.checkCancellation()
            return image
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
}

struct OCRSourceThumbnail: View {
    let url: URL
    let openPreview: () -> Void
    @State private var image: CGImage?
    @State private var unavailable = false

    var body: some View {
        Button(action: openPreview) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.high).scaledToFit()
                    } else if unavailable {
                        Image(systemName: "photo.badge.exclamationmark")
                            .foregroundStyle(.secondary)
                    } else { ProgressView().controlSize(.small) }
                }
                .frame(width: 64, height: 64)
                .background(AppColors.primaryLight.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(4)
                    .background(AppColors.cardBackground, in: Circle())
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .help("点击放大查看原图")
        .accessibilityLabel("预览原图：\(url.lastPathComponent)")
        .task(id: url) {
            image = nil; unavailable = false
            do { image = try await OCRPreviewLoader.load(url, maxDimension: 160) }
            catch is CancellationError {} catch { unavailable = true }
        }
    }
}

struct OCRSourcePreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var errorMessage: String?
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("原图预览").font(.headline)
                    Text(url.lastPathComponent)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(url.path)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }

            if let image {
                GeometryReader { geometry in
                    let fit = min(1, min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height)))
                    let size = CGSize(width: CGFloat(image.width) * fit * zoom, height: CGFloat(image.height) * fit * zoom)
                    ScrollView([.horizontal, .vertical]) {
                        Image(decorative: image, scale: 1)
                            .resizable().interpolation(.high)
                            .frame(width: size.width, height: size.height)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                            .accessibilityLabel("\(url.lastPathComponent) 的原图")
                    }
                }
                .background(Color.gray.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 12) {
                    Button { zoom = max(1, zoom - 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                        .accessibilityLabel("缩小原图").disabled(zoom <= 1)
                    Slider(value: $zoom, in: 1...4, step: 0.25)
                        .frame(width: 180).accessibilityLabel("原图缩放")
                    Button { zoom = min(4, zoom + 0.5) } label: { Image(systemName: "plus.magnifyingglass") }
                        .accessibilityLabel("放大原图").disabled(zoom >= 4)
                    Text("\(zoom, specifier: "%.2g")×")
                        .monospacedDigit().frame(width: 44, alignment: .trailing)
                    Button("适应窗口") { zoom = 1 }
                }
                .buttonStyle(.bordered)
                .font(.system(size: 12))
            } else if let errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                    Text("无法预览原图").font(.headline)
                    Text(errorMessage).font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("原图可能已被移动、删除或无法读取；识别文字仍可编辑和导出。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("正在加载原图…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(width: 760, height: 600)
        .task(id: url) {
            do { image = try await OCRPreviewLoader.load(url, maxDimension: 4096) }
            catch is CancellationError {} catch { errorMessage = error.localizedDescription }
        }
    }
}
#endif
