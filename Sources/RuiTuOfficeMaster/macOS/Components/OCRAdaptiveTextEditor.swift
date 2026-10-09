#if os(macOS)
import SwiftUI
import AppKit

/// 使用与编辑器一致的字体和换行宽度，中文、空行和窗口缩放均参与测量。
@MainActor enum OCRTextLayout {
    static let collapsedLimit: CGFloat = 180
    static let expandedLimit: CGFloat = 560

    static func contentHeight(text: String, width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 12 else { return 52 }
        let storage = NSTextStorage(string: text + "\u{200B}", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 5
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        return max(52, ceil(layout.usedRect(for: container).height) + 12)
    }
}

struct OCRAdaptiveTextEditor: View {
    @Binding var text: String
    let label: String
    @State private var width: CGFloat = 600
    @State private var expanded = false

    var body: some View {
        let contentHeight = OCRTextLayout.contentHeight(text: text, width: width)
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .frame(height: min(contentHeight, expanded ? OCRTextLayout.expandedLimit : OCRTextLayout.collapsedLimit))
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { width = geometry.size.width }
                            .onChange(of: geometry.size.width) { _, value in width = value }
                    }
                }
                .accessibilityLabel(label)

            if contentHeight > OCRTextLayout.collapsedLimit {
                HStack {
                    Button {
                        expanded.toggle()
                    } label: {
                        Label(expanded ? "收起" : "展开阅读", systemImage: expanded ? "chevron.up" : "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(label)：\(expanded ? "收起" : "展开阅读")")
                    if expanded && contentHeight > OCRTextLayout.expandedLimit {
                        Text("可在文字区域内继续滚动")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 12))
            }
        }
    }
}
#endif
