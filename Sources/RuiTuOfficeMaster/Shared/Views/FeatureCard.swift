import SwiftUI

/// 通用功能卡片组件 — 用于首页功能展示
struct FeatureCard: View {
    let title: String
    let description: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 32))
                    .foregroundColor(AppColors.primary)
                    .frame(height: 40)

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)

                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(height: 48)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(AppColors.cardBackground)
            .cornerRadius(12)
            .shadow(
                color: .black.opacity(isHovered ? 0.12 : 0.06),
                radius: isHovered ? 12 : 8,
                y: isHovered ? 4 : 2
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isHovered ? AppColors.primary.opacity(0.5) : Color.clear,
                        lineWidth: 1.5
                    )
            )
            .offset(y: isHovered ? -2 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}
