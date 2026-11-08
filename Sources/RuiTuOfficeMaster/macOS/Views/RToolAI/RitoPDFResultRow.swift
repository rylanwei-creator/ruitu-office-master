import SwiftUI
import AppKit

struct RitoPDFResultRow: View {
    let result: RToolAIResult
    var fallbackPath: String? = nil
    var associate: (() -> Void)? = nil
    @State private var error: String?
    @State private var status: String?
    private var file: RitoResultFile? {
        result.fileReference ?? fallbackPath.map { .init(url: URL(fileURLWithPath: $0)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(result.sourceName, systemImage: "doc.richtext")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    .onTapGesture(count: 2) { perform { try RitoResultFileActions.open($0) } }
                    .help("双击文件名打开 PDF")
                    .accessibilityAction(named: "打开 PDF") { perform { try RitoResultFileActions.open($0) } }
                Button("复制文件") {
                    perform { try RitoResultFileActions.copy($0); status = "文件已复制，可在 Finder 中粘贴。" }
                }.controlSize(.small).disabled(file == nil)
                    .accessibilityLabel("复制文件：\(result.sourceName)")
            }
            Text(result.detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("打开 PDF") { perform { try RitoResultFileActions.open($0) } }.disabled(file == nil)
                    .accessibilityLabel("打开 PDF：\(result.sourceName)")
                Button("在 Finder 中显示") { perform { try RitoResultFileActions.reveal($0) } }.disabled(file == nil)
                if let associate { Button(file == nil ? "关联结果文件…" : "重新关联…", action: associate) }
            }.controlSize(.small)
            if file == nil { Text("这条旧记录未保存文件位置，请关联对应的 PDF。").font(.caption2).foregroundStyle(.secondary) }
            if let status { Text(status).font(.caption2).foregroundStyle(.secondary) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .alert("无法访问结果文件", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("好") { error = nil }
            } message: { Text(error ?? "") }
    }
    private func perform(_ action: (RitoResultFile) throws -> Void) {
        do { guard let file else { throw RitoResultFileError.unavailable }; try action(file) }
        catch { self.error = error.localizedDescription; status = nil }
    }
}
