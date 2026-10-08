import SwiftUI
import AppKit

/// 页面标题组件：Logo + 标题 + 副标题，所有功能页统一使用
struct PageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                logoImage
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
            }
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)
        }
    }

    @ViewBuilder
    private var logoImage: some View {
        if let logoPath = AppResources.bundle.path(forResource: "Logo", ofType: "png") {
            if let nsImage = NSImage(contentsOfFile: logoPath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 36)
            }
        }
    }
}
