import SwiftUI

/// 隐私声明条：所有功能页底部统一使用
struct PrivacyNoticeView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 12))
                .foregroundColor(AppColors.success)
            Text("文件工具在本机处理；语音识别仅使用本地能力，反馈功能需联网")
                .font(.system(size: 12))
                .foregroundColor(AppColors.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 12)
    }
}
