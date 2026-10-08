#if os(macOS)
import SwiftUI

/// 帮助与反馈 — 软件内静默直发，无需跳出 App
struct FeedbackSettingsView: View {
    private let feedbackTypes = ["功能建议", "Bug 反馈", "使用问题", "其他"]

    @State private var feedbackType = "功能建议"
    @State private var contact = ""
    @State private var message = ""
    @State private var isSending = false
    @State private var showEmptyWarning = false

    // 结果提示
    @State private var resultToast: FeedbackToast?

    // 月度上限
    @State private var monthlyCount = FeedbackLimitTracker.successCount
    @State private var showLimitAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // 反馈表单
                SettingsSection(title: "提交反馈") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("反馈类型")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textSecondary)
                        Picker("", selection: $feedbackType) {
                            ForEach(feedbackTypes, id: \.self) { type in
                                Text(type).tag(type)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 500)
                    }

                    Divider().opacity(0.5)

                    // 联系方式（可选）
                    VStack(alignment: .leading, spacing: 4) {
                        Text("联系方式（选填）")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppColors.textSecondary)
                        TextField("邮箱或微信，方便我们回复你", text: $contact)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textPrimary)
                            .padding(10)
                            .background(AppColors.background)
                            .cornerRadius(6)
                    }

                    Divider().opacity(0.5)

                    // 反馈内容
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("反馈内容")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColors.textSecondary)
                            Text("（必填）")
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.error)
                            Spacer()
                            if showEmptyWarning {
                                Text("请输入反馈内容")
                                    .font(.system(size: 12))
                                    .foregroundColor(AppColors.error)
                            }
                        }
                        TextEditor(text: $message)
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textPrimary)
                            .frame(minHeight: 150)
                            .padding(8)
                            .background(AppColors.background)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        showEmptyWarning
                                            ? AppColors.error.opacity(0.6)
                                            : Color.gray.opacity(0.2),
                                        lineWidth: 1
                                    )
                            )
                    }

                    // 提交按钮
                    HStack {
                        Spacer()
                        Button { submitFeedback() } label: {
                            HStack(spacing: 8) {
                                if isSending {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "paperplane.fill")
                                }
                                Text(isSending ? "发送中..." : "发送反馈")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isSending ? AppColors.primary.opacity(0.6) : AppColors.primary)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSending || !FeedbackLimitTracker.canSubmit)
                        .opacity(FeedbackLimitTracker.canSubmit ? 1 : 0.5)
                        Spacer()
                    }
                    .padding(.top, 8)

                    // 余量提示
                    if !FeedbackLimitTracker.canSubmit {
                        Text("本月反馈通道已达上限，暂时无法提交，下月恢复，感谢您的理解与支持")
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.error.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 6)
                    } else if FeedbackLimitTracker.isNearLimit {
                        Text("本月反馈余量不多（剩余 \(FeedbackLimitTracker.remaining) 次）")
                            .font(.system(size: 11))
                            .foregroundColor(Color.orange.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 6)
                    }
                }

                // 隐私说明
                SettingsSection(title: "隐私说明") {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 22))
                            .foregroundColor(AppColors.success)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("你的反馈仅通过加密通道发送")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(AppColors.textPrimary)
                            Text("无需注册账号，不经过第三方服务器，不收集个人信息。发送过程全程加密，反馈内容直达开发者邮箱。")
                                .font(.system(size: 12))
                                .foregroundColor(AppColors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast = resultToast {
                ResultToastView(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: resultToast)
        .alert("提交失败", isPresented: $showLimitAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("本月反馈通道已达上限，暂时无法提交，下月恢复，感谢您的理解与支持")
        }
    }

    // MARK: - 提交反馈

    private func submitFeedback() {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showEmptyWarning = true
            return
        }

        // 前置拦截：已达月度上限
        guard FeedbackLimitTracker.canSubmit else {
            showLimitAlert = true
            return
        }

        showEmptyWarning = false
        isSending = true
        resultToast = nil

        FeedbackService().send(
            feedbackType: feedbackType,
            contact: contact,
            message: message
        ) { result in
            isSending = false
            switch result {
            case .success:
                monthlyCount = FeedbackLimitTracker.successCount
                message = ""
                contact = ""
                showToast(.success, "反馈发送成功，感谢你的建议")
            case .failure(let error):
                if case .monthlyLimitReached = error {
                    monthlyCount = FeedbackLimitTracker.successCount
                    showToast(.failure, "本月反馈通道已达上限，暂时无法提交，下月恢复，感谢您的理解与支持")
                } else {
                    showToast(.failure, "发送失败，请检查网络后重试")
                }
            }
        }
    }

    private func showToast(_ type: FeedbackToastType, _ text: String) {
        resultToast = FeedbackToast(type: type, message: text)
        Task {
            try? await Task.sleep(for: .seconds(3))
            resultToast = nil
        }
    }
}

// MARK: - 反馈结果提示模型

private enum FeedbackToastType {
    case success, failure
}

private struct FeedbackToast: Equatable {
    let type: FeedbackToastType
    let message: String

    static func == (lhs: FeedbackToast, rhs: FeedbackToast) -> Bool {
        lhs.message == rhs.message && lhs.type == rhs.type
    }
}

/// 反馈结果提示横幅
private struct ResultToastView: View {
    let toast: FeedbackToast

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.type == .success
                  ? "checkmark.circle.fill"
                  : "xmark.circle.fill")
                .foregroundColor(toast.type == .success
                                 ? AppColors.success
                                 : AppColors.error)
            Text(toast.message)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AppColors.textPrimary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(AppColors.cardBackground)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.1), radius: 12, y: 4)
    }
}

#endif
