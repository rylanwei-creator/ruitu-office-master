#if os(macOS)
import SwiftUI
import AppKit

struct PDFSplitPreviewView: View {
    let viewModel: PDFToolsViewModel
    @State private var jumpText = "1"
    @State private var enlargedPage: EnlargedPDFPage?
    private var preview: PDFSplitPreviewViewModel { viewModel.splitPreview }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("拆分前预览", systemImage: "doc.text.magnifyingglass").font(.headline)
                Spacer()
                Button("重新加载") { preview.reload() }
                    .disabled(preview.isLoadingDocument)
            }
            if viewModel.selectedFiles.count > 1 {
                Picker("预览文档", selection: Binding(get: { preview.selectedURL }, set: { preview.select($0) })) {
                    ForEach(viewModel.selectedFiles, id: \.self) { url in
                        Text(url.lastPathComponent).tag(Optional(url))
                    }
                }
                Text("可切换查看每份文档。拆分一次处理一份 PDF，请在文件列表中移除其余文件。")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let url = preview.selectedURL {
                Text(url.lastPathComponent).font(.callout).textSelection(.enabled).help(url.path)
            }
            if preview.isLoadingDocument {
                ProgressView("正在读取 PDF 页数…").frame(maxWidth: .infinity, minHeight: 160)
            } else if let error = preview.documentError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.error).textSelection(.enabled)
            } else if let count = preview.pageCount {
                HStack {
                    Text("总页数：\(count) 页").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if !viewModel.splitPreviewRanges.isEmpty {
                        Text(viewModel.currentPreviewPageIsIncluded ? "当前页在拆分范围内" : "当前页不在拆分范围内")
                            .font(.caption)
                            .foregroundStyle(viewModel.currentPreviewPageIsIncluded ? AppColors.success : AppColors.textSecondary)
                    }
                }
                pageCanvas
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { pageNavigation; Spacer(); pageJump }
                    VStack(alignment: .leading, spacing: 12) { pageNavigation; pageJump }
                }
                if let error = preview.jumpError {
                    Text(error).font(.caption).foregroundStyle(AppColors.error)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.cardBackground)
        .cornerRadius(12)
        .onChange(of: preview.currentPage) { _, page in jumpText = String(page) }
        .onChange(of: preview.selectedURL) { jumpText = "1" }
        .sheet(item: $enlargedPage) { page in
            EnlargedPDFPageView(page: page)
        }
    }

    private var pageCanvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.08))
            if preview.isRenderingPage {
                ProgressView("正在加载第 \(preview.currentPage) 页…")
            } else if let image = preview.image {
                Button {
                    enlargedPage = EnlargedPDFPage(image: image, title: "\(preview.selectedURL?.lastPathComponent ?? "PDF") · 第 \(preview.currentPage) 页")
                } label: {
                    Image(nsImage: image).resizable().scaledToFit().padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("放大预览第 \(preview.currentPage) 页")
                .help("点击放大查看这一页")
            } else if let error = preview.pageError {
                VStack(spacing: 12) {
                    Text(error).foregroundStyle(AppColors.error)
                    Button("重试此页") { preview.goToPage(preview.currentPage) }
                }.padding()
            }
        }
        .frame(height: 400)
    }

    private var pageNavigation: some View {
        HStack(spacing: 12) {
            Button { preview.goToPage(preview.currentPage - 1) } label: {
                Label("上一页", systemImage: "chevron.left")
            }.disabled(preview.currentPage <= 1)
            Text("第 \(preview.currentPage) / \(preview.pageCount ?? 0) 页").monospacedDigit()
            Button { preview.goToPage(preview.currentPage + 1) } label: {
                Label("下一页", systemImage: "chevron.right")
            }.disabled(preview.currentPage >= (preview.pageCount ?? 0))
        }.buttonStyle(.bordered)
    }

    private var pageJump: some View {
        HStack(spacing: 8) {
            Text("跳至")
            TextField("页码", text: $jumpText).textFieldStyle(.roundedBorder).frame(width: 60)
                .accessibilityLabel("预览页码")
                .onSubmit { preview.jump(to: jumpText) }
            Button("跳转") { preview.jump(to: jumpText) }.buttonStyle(.bordered)
        }
    }
}

private struct EnlargedPDFPage: Identifiable {
    let id = UUID()
    let image: NSImage
    let title: String
}

private struct EnlargedPDFPageView: View {
    let page: EnlargedPDFPage
    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(page.title).font(.headline).lineLimit(2)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Text("缩放 \(Int(scale * 100))%")
                Slider(value: $scale, in: 1...3).frame(width: 220)
                Button("适应窗口") { scale = 1 }
            }
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: page.image).resizable().scaledToFit()
                        .frame(width: geometry.size.width * scale, height: geometry.size.height * scale)
                }.background(Color.gray.opacity(0.08))
            }
        }
        .padding(20).frame(width: 760, height: 650)
    }
}
#endif
