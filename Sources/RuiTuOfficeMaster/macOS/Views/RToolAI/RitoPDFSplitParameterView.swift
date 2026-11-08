import SwiftUI

/// Reuses the ordinary PDF tool's background reader and one-page rendering cache.
struct RitoPDFSplitParameterView: View {
    let sourceURL: URL?
    @Bindable var preview: PDFSplitPreviewViewModel
    @Binding var rangesText: String
    @State private var jumpText = "1"
    private var selection: PDFSplitSelection { .init(text:rangesText,pageCount:preview.pageCount) }

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Label("当前 PDF",systemImage:"doc.richtext").font(.headline)
                Spacer()
                if sourceURL != nil {
                    Button("重新加载") { preview.reload() }.controlSize(.small).disabled(preview.isLoadingDocument)
                }
            }
            if let sourceURL {
                Text(sourceURL.lastPathComponent).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal:false,vertical:true)
            } else {
                Label("此历史任务没有保留原 PDF 的访问权限，请重新添加 PDF 并发起拆分。",systemImage:"exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if preview.isLoadingDocument {
                ProgressView("正在读取 PDF 总页数…").controlSize(.small)
            } else if let error = preview.documentError {
                Label(error,systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.red).textSelection(.enabled)
            } else if let count = preview.pageCount {
                Text("总页数：\(count) 页").font(.system(size:15,weight:.semibold))
                    .accessibilityLabel("PDF 总页数：\(count) 页")
            }

            VStack(alignment:.leading,spacing:6) {
                Text("页码范围").font(.callout.weight(.medium))
                TextField("例如 1-3,5",text:$rangesText).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("PDF 拆分页码范围").disabled(sourceURL == nil)
                Text("每个逗号分隔的范围生成一个 PDF；例如 1-3,5 将生成第 1–3 页和第 5 页两份文件。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            if let error = selection.error, preview.isReady {
                Label(error,systemImage:"exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal:false,vertical:true)
            }
            if preview.isReady {
                if !preview.sourceIsCurrent {
                    Label("原 PDF 已变化，请重新加载后核对页码。",systemImage:"exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                }
                Divider()
                if selection.isValid {
                    Text("将生成 \(selection.ranges.count) 个 PDF，共 \(selection.totalPages) 页（重叠范围分别计数）")
                        .font(.caption.weight(.medium))
                    ScrollView(.horizontal) {
                        HStack(spacing:8) {
                            ForEach(Array(selection.ranges.enumerated()),id:\.offset) { index, range in
                                Button("文件 \(index + 1) · 第 \(range.start)\(range.end == range.start ? "" : "–\(range.end)") 页") {
                                    preview.goToPage(range.start)
                                }.controlSize(.small)
                            }
                        }
                    }
                }
                HStack {
                    Text("拆分预览").font(.callout.weight(.semibold))
                    Spacer()
                    Text(selection.ranges.contains { ($0.start...$0.end).contains(preview.currentPage) }
                         ? "当前页已包含" : "当前页未包含").font(.caption2).foregroundStyle(.secondary)
                }
                ZStack {
                    RoundedRectangle(cornerRadius:8).fill(Color.primary.opacity(0.035))
                    if preview.isRenderingPage {
                        ProgressView("正在加载第 \(preview.currentPage) 页…").controlSize(.small)
                    } else if let image = preview.image {
                        Image(nsImage:image).resizable().scaledToFit().padding(8)
                            .accessibilityLabel("PDF 第 \(preview.currentPage) 页预览")
                    } else if let error = preview.pageError {
                        VStack(spacing:8) {
                            Text(error).font(.caption).foregroundStyle(.red)
                            Button("重试此页") { preview.goToPage(preview.currentPage) }.controlSize(.small)
                        }.padding(10)
                    }
                }.frame(height:230)
                HStack(spacing:8) {
                    Button("上一页") { preview.goToPage(preview.currentPage - 1) }.disabled(preview.currentPage <= 1)
                    Text("第 \(preview.currentPage) / \(preview.pageCount ?? 0) 页").font(.caption).monospacedDigit()
                    Button("下一页") { preview.goToPage(preview.currentPage + 1) }
                        .disabled(preview.currentPage >= (preview.pageCount ?? 0))
                    Spacer(minLength:8)
                    TextField("页码",text:$jumpText).textFieldStyle(.roundedBorder).frame(width:48)
                        .accessibilityLabel("PDF 预览跳转页码").onSubmit { preview.jump(to:jumpText) }
                    Button("跳转") { preview.jump(to:jumpText) }
                }.controlSize(.small)
                if let error = preview.jumpError { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }.padding(12).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:10))
            .task(id:sourceURL) { preview.select(sourceURL) }
            .onChange(of:rangesText) { focusFirstSelection() }
            .onChange(of:preview.pageCount) { focusFirstSelection() }
            .onChange(of:preview.currentPage) { _, page in jumpText = String(page) }
            .onDisappear { preview.select(nil) }
    }
    private func focusFirstSelection() {
        guard let first = selection.ranges.first?.start, first != preview.currentPage else { return }
        preview.goToPage(first)
    }
}
