import SwiftUI
import AppKit

/// Shows the recorded destination hierarchy without reading or changing the filesystem.
struct OrganizerFolderTree: View {
    let items: [OrganizerItem]
    let configuration: OrganizerConfiguration
    let isPreview: Bool
    @State private var collapsed: Set<String> = []

    private struct Folder: Identifiable {
        let destination: URL
        let items: [OrganizerItem]
        var id: String { destination.path }
    }
    private var folders: [Folder] {
        let order = ["图片", "文档", "视频", "音频", "压缩包", "代码", "其他"]
        return Dictionary(grouping: items, by: { $0.destination.deletingLastPathComponent().path })
            .values.map { Folder(destination: $0[0].destination.deletingLastPathComponent(), items: $0) }
            .sorted {
                let a = order.firstIndex(of: $0.destination.lastPathComponent) ?? order.count
                let b = order.firstIndex(of: $1.destination.lastPathComponent) ?? order.count
                return a == b ? $0.id < $1.id : a < b
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rootHeader
            Divider()
            if items.isEmpty {
                Text("没有文件可显示").foregroundStyle(.secondary).padding(20)
            } else {
                folderList
            }
        }
        .background(AppColors.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppColors.primary.opacity(0.12)))
        .onChange(of: items.map(\.id)) { _, _ in collapsed = [] }
    }
    private var rootHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(AppColors.primary)
            VStack(alignment: .leading, spacing: 4) {
                Text(configuration.destination.lastPathComponent).font(.headline)
                Text(configuration.destination.path).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(isPreview ? "预期目录结构" : "整理记录中的分类")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(14).help(configuration.destination.path)
    }
    private var folderList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(folders) { folder in folderSection(folder) }
            }.padding(14)
        }.frame(height: min(480, CGFloat(items.count * 82 + folders.count * 66 + 28)))
    }
    private func folderSection(_ folder: Folder) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { !collapsed.contains(folder.id) },
            set: { if $0 { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) } }
        )) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(folder.items) { item in
                    fileRow(item)
                    if item.id != folder.items.last?.id { Divider().padding(.leading, 30) }
                }
            }.padding(.top, 8).padding(.leading, 12)
        } label: { folderHeader(folder) }
        .padding(12)
        .background(AppColors.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.primary.opacity(0.12)))
    }
    private func folderHeader(_ folder: Folder) -> some View {
        HStack(spacing: 8) {
            Label(folder.destination.lastPathComponent, systemImage: "folder.fill")
                .font(.headline).foregroundStyle(AppColors.primary)
            Text("\(folder.items.count) 个文件").font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(folderSummary(folder)).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }.padding(.vertical, 5).help(folder.destination.path)
    }

    private func fileRow(_ item: OrganizerItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fileIcon(item.category)).foregroundStyle(.secondary)
                .frame(width: 20).padding(.top, 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.destination.lastPathComponent).font(.body.weight(.medium))
                    .lineLimit(2).textSelection(.enabled).help(item.destination.path)
                Text("来源：\(sourceLabel(item))").font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled).help(item.source.path)
                if let message = item.message {
                    Text(message).font(.caption).foregroundStyle(statusColor(item))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Label(statusLabel(item), systemImage: statusIcon(item))
                .font(.caption.weight(.medium)).foregroundStyle(statusColor(item))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(statusColor(item).opacity(0.09), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.vertical, 10)
        .contextMenu {
            Button("复制来源路径") { copyPath(item.source) }
            Button("复制目标路径") { copyPath(item.destination) }
        }
    }
    private func sourceLabel(_ item: OrganizerItem) -> String {
        // Relative to the selected root, retaining the root name and original filename.
        let source = item.source.standardizedFileURL.path
        let root = configuration.roots.sorted { $0.path.count > $1.path.count }.first {
            source.hasPrefix($0.standardizedFileURL.path + "/")
        }
        guard let root else { return item.source.path }
        let suffix = source.dropFirst(root.standardizedFileURL.path.count + 1)
        return root.lastPathComponent + "/" + suffix
    }
    private func folderSummary(_ folder: Folder) -> String {
        if isPreview {
            let skipped = folder.items.filter { $0.phase == .skipped }.count
            return "待\(configuration.mode.rawValue) \(folder.items.count - skipped)" + (skipped > 0 ? " · 跳过 \(skipped)" : "")
        }
        let phases: [OrganizerPhase] = [.completed, .failed, .skipped, .undone, .pending, .prepared, .copied, .restoring]
        return phases.compactMap { phase -> String? in
            let matching = folder.items.filter { $0.phase == phase }
            guard let first = matching.first else { return nil }
            return "\(statusLabel(first)) \(matching.count)"
        }.joined(separator: " · ")
    }
    private func statusLabel(_ item: OrganizerItem) -> String {
        if isPreview {
            if item.phase == .skipped { return "跳过，不执行" }
            return item.source.lastPathComponent != item.destination.lastPathComponent
                ? "已编号 · 待\(configuration.mode.rawValue)" : "待\(configuration.mode.rawValue)"
        }
        switch item.phase {
        case .completed: return "已\(configuration.mode.rawValue)"
        case .pending: return "未处理"
        case .skipped: return "已跳过"
        case .undone: return "已撤销"
        case .prepared: return "尚未提交"
        case .restoring: return "恢复未完成"
        default: return item.phase.rawValue
        }
    }
    private func statusColor(_ item: OrganizerItem) -> Color {
        if isPreview { return item.phase == .skipped ? .secondary : AppColors.primary }
        switch item.phase {
        case .completed: return .green
        case .failed: return .red
        case .prepared, .copied, .restoring, .pending: return .orange
        case .skipped, .undone: return .secondary
        }
    }
    private func statusIcon(_ item: OrganizerItem) -> String {
        if isPreview { return item.phase == .skipped ? "minus.circle" : "arrow.right" }
        switch item.phase {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .skipped: return "minus.circle"
        case .undone: return "arrow.uturn.backward"
        default: return "clock"
        }
    }
    private func fileIcon(_ category: String) -> String {
        switch category {
        case "图片": return "photo"
        case "视频": return "film"
        case "音频": return "waveform"
        case "压缩包": return "archivebox"
        case "代码": return "chevron.left.forwardslash.chevron.right"
        default: return "doc.text"
        }
    }
    private func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }
}
