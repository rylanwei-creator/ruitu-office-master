#if os(macOS)
import SwiftUI

/// 侧边栏导航
struct SidebarView: View {
    @Binding var selectedNav: NavItem

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
    }
}

#endif
