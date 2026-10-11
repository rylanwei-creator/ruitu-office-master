#if os(macOS)
import SwiftUI

/// 侧边栏导航
struct SidebarView: View {
    @Binding var selectedNav: NavItem
    @State private var showUpdates = false
    private let updates = AppUpdateViewModel.shared

    var body: some View {
        List(selection: $selectedNav) {
            // 工具分组
            Section {
                ForEach(NavItem.allCases.filter { !$0.isUtility }) { item in
                    Label(item.rawValue, systemImage: item.systemImage)
                        .font(.system(size: 14))
                        .padding(.vertical, 2)
                        .tag(item)
                }
            } header: {
                Text("工具")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(1)
            }

            // 其他分组
            Section {
                ForEach(NavItem.allCases.filter { $0.isUtility }) { item in
                    Label(item.rawValue, systemImage: item.systemImage)
                        .font(.system(size: 14))
                        .padding(.vertical, 2)
                        .tag(item)
                }
            } header: {
                Text("其他")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(1)
            }
        }
        .listStyle(.sidebar)
        .background(AppColors.sidebarBackground)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Divider()
                Button { showUpdates = true; Task { await updates.check() } } label: {
                    Label(updates.isChecking ? "正在检查更新…" : "检查更新", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                }.buttonStyle(.borderedProminent).tint(AppColors.primary)
                Text("当前版本 \(updates.currentVersion)").font(.caption).foregroundStyle(AppColors.textSecondary)
            }.padding(.horizontal, 12).padding(.bottom, 12).background(AppColors.sidebarBackground)
        }
        .sheet(isPresented: $showUpdates) { SoftwareUpdateSheet() }
    }
}

#endif
