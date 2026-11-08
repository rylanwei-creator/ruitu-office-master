#if os(macOS)
import SwiftUI

struct RitoAIHistoryView: View {
    @Bindable var model: RToolAIViewModel
    var returnToTools: () -> Void
    @State private var renaming: RitoAIConversation?
    @State private var renameText = ""
    @State private var search = ""
    @State private var deleting: RitoAIConversation?
    private var filtered: [RitoAIConversation] {
        model.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.newConversation() } label: {
                Label("新聊天", systemImage: "square.and.pencil")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8).padding(.vertical, 10)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("新聊天")
            Divider()
            HStack { Text("聊天历史").font(.system(size: 13, weight: .semibold)); Spacer(); Text("\(model.conversations.count)").font(.caption).foregroundStyle(.secondary) }
            TextField("搜索对话", text: $search).textFieldStyle(.roundedBorder).font(.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(filtered) { conversation in
                        HStack(alignment: .top, spacing: 3) {
                            Button { model.openConversation(conversation.id) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(conversation.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(conversation.updatedAt, format: .dateTime.month().day().hour().minute()).font(.system(size: 10)).foregroundStyle(.secondary).help("最后修改时间；仅查看不会改变时间或排序")
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("打开对话：\(conversation.title)")
                            Menu {
                                Button("重命名") { renameText = conversation.title; renaming = conversation }
                                Button("删除对话", role: .destructive) { deleting = conversation }
                            } label: { Image(systemName: "ellipsis").font(.system(size: 11)) }
                                .menuStyle(.borderlessButton).fixedSize().padding(.top, 9).help("对话操作")
                            Button { deleting = conversation } label: { Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(.secondary) }
                                .buttonStyle(.plain).padding(.top, 11).padding(.trailing, 8).accessibilityLabel("删除对话：\(conversation.title)")
                        }.background(conversation.id == model.conversationID ? RToolAIStyle.accent.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                    }
                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 22)).foregroundStyle(.tertiary)
                            Text(search.isEmpty ? "还没有历史对话" : "没有匹配的对话").font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.top, 35)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: returnToTools) { Label("返回工具模式", systemImage: "square.grid.2x2").frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).font(.caption).padding(.vertical, 6)
            Text("最近 30 条 · 仅存本机\n保存已发送消息，附件仅存信息与小尺寸预览。").font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AppColors.sidebarBackground)
            .disabled(model.isChoosingFiles)
            .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("对话名称", text: $renameText)
                Button("保存") { if let id = renaming?.id { model.renameConversation(id, title: renameText) }; renaming = nil }
                Button("取消", role: .cancel) { renaming = nil }
            }
            .confirmationDialog("删除这条对话？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除对话", role: .destructive) { if let id = deleting?.id { model.deleteConversation(id) }; deleting = nil }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { Text("删除本机聊天记录，不会删除任何附件文件。") }
    }
}
#endif
