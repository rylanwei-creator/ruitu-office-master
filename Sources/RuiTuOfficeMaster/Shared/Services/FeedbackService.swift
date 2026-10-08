import Foundation

/// 反馈发送服务 — 通过 Web3Forms API 后台静默发送，无需注册任何账号
struct FeedbackService {
    private let endpoint = "https://api.web3forms.com/submit"
    private let accessKey = "a0d4d642-6ade-4654-ae0f-05d410ba5b47"
    private let targetEmail = "wjr22917@outlook.com"
    private let appVersion = "1.0.0"

    /// 后台发送反馈，完成后主线程回调成功/失败
    func send(
        feedbackType: String,
        contact: String,
        message: String,
        completion: @escaping (Result<Void, FeedbackError>) -> Void
    ) {
        let subject = "[锐途办公大师 用户反馈] \(feedbackType)"

        let macOSVersion = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "macOS \(macOSVersion.majorVersion).\(macOSVersion.minorVersion).\(macOSVersion.patchVersion)"

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "zh_CN")
        let timestamp = formatter.string(from: Date())

        let emailBody = """
        反馈类型：\(feedbackType)
        联系方式：\(contact.isEmpty ? "未填写" : contact)
        软件版本：\(appVersion)
        系统版本：\(systemVersion)
        提交时间：\(timestamp)

        --- 反馈内容 ---
        \(message)
        """

        guard let url = URL(string: endpoint) else {
            completion(.failure(.sendFailed("接口地址无效")))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: String] = [
            "access_key": accessKey,
            "subject": subject,
            "message": emailBody,
            "from_name": contact.isEmpty ? "锐途用户" : contact
        ]

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(.sendFailed("请求数据异常")))
            return
        }
        request.httpBody = httpBody

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                DispatchQueue.main.async {
                    completion(.failure(.sendFailed(error.localizedDescription)))
                }
                return
            }

            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let success = json["success"] as? Bool else {
                DispatchQueue.main.async {
                    completion(.failure(.sendFailed("服务器响应异常")))
                }
                return
            }

            DispatchQueue.main.async {
                if success {
                    FeedbackLimitTracker.increment()
                    completion(.success(()))
                } else {
                    let msg = json["message"] as? String ?? "未知错误"
                    if isOverLimitMessage(msg) {
                        completion(.failure(.monthlyLimitReached))
                    } else {
                        completion(.failure(.sendFailed(msg)))
                    }
                }
            }
        }.resume()
    }

    /// 判断 API 返回的错误是否为额度超限
    private func isOverLimitMessage(_ msg: String) -> Bool {
        let lower = msg.lowercased()
        let keywords = ["limit", "quota", "exceeded", "reached", "maximum", "exhausted", "额度", "超出", "上限"]
        return keywords.contains(where: lower.contains)
    }
}

// MARK: - 错误类型

enum FeedbackError: LocalizedError {
    case sendFailed(String)
    case monthlyLimitReached

    var errorDescription: String? {
        switch self {
        case .sendFailed(let msg):
            return msg
        case .monthlyLimitReached:
            return "本月反馈通道已达上限，暂时无法提交，下月恢复，感谢您的理解与支持"
        }
    }
}
