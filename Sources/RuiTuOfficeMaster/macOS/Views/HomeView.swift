#if os(macOS)
import SwiftUI

struct HomeView: View {
    @Binding var selectedNav: NavItem
    @State private var search = ""
    @State private var recentTools: [NavItem] = []
    @AppStorage("favoriteTools.v1") private var favoriteStorage = ""
    private var favorites: Set<String> { Set(favoriteStorage.split(separator: "|").map(String.init)) }
    private var favoriteEntries: [ToolCatalogEntry] { ToolCatalog.tools.filter { favorites.contains($0.id) } }
    private var filtered: [ToolCatalogEntry] { ToolCatalog.search(search) }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PageHeader(title: "锐途办公大师", subtitle: "本机处理文件，快速找到你需要的工具")
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").foregroundStyle(AppColors.textSecondary)
                        TextField("搜索工具，例如：压缩、证件照、PDF、字幕", text: $search).textFieldStyle(.plain)
                        if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("清空搜索") }
                    }.padding(12).background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                    Button { selectedNav = .tasks } label: {
                        HStack {
                            Label("任务中心", systemImage: "list.bullet.clipboard")
                            Spacer()
                            Text(FileTaskManager.shared.activeCount > 0 ? "\(FileTaskManager.shared.activeCount) 个任务处理中或等待中" : "查看图片批处理进度与结果")
                                .font(.callout).foregroundStyle(AppColors.textSecondary)
                            Image(systemName: "chevron.right")
                        }.padding(16).background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                    if search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if !favoriteEntries.isEmpty { toolSection("收藏工具", entries: favoriteEntries) }
                        if !recentTools.isEmpty {
                            HStack(spacing: 10) {
                                Text("最近使用").font(.callout).foregroundStyle(AppColors.textSecondary)
                                ForEach(recentTools) { item in Button(item.rawValue) { selectedNav = item }.buttonStyle(.bordered) }
                            }
                        }
                    }
                    if filtered.isEmpty {
                        Spacer(minLength: 0)
                        ContentUnavailableView.search(text: search)
                            .frame(maxWidth: .infinity)
                        Spacer(minLength: 0)
                    } else {
                        toolSection(search.isEmpty ? "全部工具" : "搜索结果（\(filtered.count)）", entries: filtered)
                    }
                }
                .frame(minHeight: filtered.isEmpty ? max(0, geometry.size.height - 64) : nil, alignment: .top)
                .padding(32)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
        }.background(AppColors.background)
        .onAppear(perform: loadRecent)
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) { _ in loadRecent() }
    }
    private func toolSection(_ title: String, entries: [ToolCatalogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(AppColors.textPrimary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 16)], spacing: 16) {
                ForEach(entries) { entry in
                    VStack(spacing: 0) {
                        FeatureCard(title: entry.item.rawValue, description: entry.description, systemImage: entry.item.systemImage) { selectedNav = entry.item }
                        HStack {
                            Spacer()
                            Button { toggleFavorite(entry.id) } label: {
                                Label(favorites.contains(entry.id) ? "已收藏" : "收藏", systemImage: favorites.contains(entry.id) ? "star.fill" : "star")
                                    .font(.caption)
                            }.buttonStyle(.plain).foregroundStyle(AppColors.primary).padding(.top, 8)
                        }
                    }
                }
            }
        }
    }
    private func toggleFavorite(_ id: String) {
        var values = favorites
        if values.contains(id) { values.remove(id) } else { values.insert(id) }
        favoriteStorage = values.sorted().joined(separator: "|")
    }
    private func loadRecent() {
        var unique: [NavItem] = []
        for record in HistoryService().fetchAll() {
            guard let item = NavItem(rawValue: record.toolName), ToolCatalog.tools.contains(where: { $0.item == item }), !unique.contains(item) else { continue }
            unique.append(item)
            if unique.count == 3 { break }
        }
        recentTools = unique
    }
}
#endif
