import SwiftUI

struct RitoAISettingsView: View {
    @Bindable var configuration = RitoAIConfiguration.shared
    @Bindable var model = RitoModelManager.shared
    @State private var key = ""
    @State private var status: String?
    @State private var testing = false
    @State private var connectionTest: Task<Void, Never>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Rito AI").font(.title2.bold())
                Picker("AI 模式", selection: $configuration.mode) {
                    ForEach(RitoAIConfiguration.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(testing)
                if configuration.mode == .local {
                    Text("Qwen3 1.7B · 4-bit · MLX").font(.headline)
                    Text("Apple Silicon 本地运行，无 API 调用费，无需 Ollama。首次下载约 0.93 GB，完成校验后可离线聊天。模型不包含在安装包中。").font(.callout)
                    if model.busy { ProgressView(value: model.progress) }
                    Text(model.detail).font(.caption).textSelection(.enabled)
                    HStack {
                        if model.busy { Button("取消下载 / 校验", action: model.cancel) }
                        else {
                            Button(model.phase == .failed || model.phase == .cancelled ? "重试下载" : "下载模型", action: model.download)
                            Button("导入已下载模型…") { Task { await model.importDirectory() } }
                            Button("重新校验", action: model.check)
                        }
                    }.controlSize(.small)
                    Button("卸载运行中的模型 / 释放内存", action: model.unload).controlSize(.small)
                    Text("仅卸载内存，不删除已下载文件。输入和生成长度有上限；本地对话内容不发送到服务商。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("服务商", selection: $configuration.provider) { ForEach(RitoAIProviderKind.allCases) { Text($0.rawValue).tag($0) } }.disabled(testing)
                    TextField("HTTPS Chat Completions 完整地址", text: $configuration.endpoint).textFieldStyle(.roundedBorder).disabled(testing)
                    TextField("模型 ID（豆包可填写推理接入点 ID）", text: $configuration.modelID).textFieldStyle(.roundedBorder).disabled(testing)
                    SecureField("你自己的 API Key，仅保存到 macOS Keychain", text: $key).textFieldStyle(.roundedBorder).disabled(testing)
                    HStack {
                        Button("保存密钥") { saveKey() }.disabled(key.isEmpty || testing)
                        Button("删除当前密钥") { do { try configuration.deleteKey(); status = "已删除当前服务与地址的密钥。" } catch { status = error.localizedDescription } }.disabled(testing)
                        Button(testing ? "测试中…" : "测试连接") { testConnection() }.disabled(testing)
                        if testing { Button("停止测试") { connectionTest?.cancel() } }
                    }.controlSize(.small)
                    Text("发送消息或测试连接时才读取钥匙串。内测版更新后 macOS 可能再次要求授权；取消后可重试，不会删除已保存密钥。授权窗口需由你本人确认。").font(.caption).foregroundStyle(.secondary)
                    Text("直接使用你的供应商账号，费用由供应商决定；连接测试也会发送一个简短真实请求。修改服务或服务器地址后需要分别保存密钥。没有开发者后端，也不会自动切换到付费来源。").font(.caption).foregroundStyle(.secondary)
                }
                if let status { Text(status).font(.caption).textSelection(.enabled) }
                Text("普通办公工具始终独立运行。云端模式只发送文字及有限上下文，不上传附件内容、文件路径或文件名。聊天历史保存在本机。").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 700, alignment: .leading)
        }.onAppear { if configuration.mode == .local { model.check() } }
            .onDisappear { connectionTest?.cancel() }
            .onChange(of: configuration.mode) { _, value in key = ""; status = nil; if value == .local { model.check() } }
            .onChange(of: configuration.provider) { _, _ in key = ""; status = nil }
    }
    private func saveKey() {
        do { try configuration.saveKey(key); key = ""; status = "密钥已保存到 macOS Keychain。" }
        catch { status = error.localizedDescription }
    }
    private func testConnection() {
        testing = true; status = nil
        connectionTest = Task {
            defer { testing = false; connectionTest = nil }
            do {
                let provider = try configuration.customProvider()
                let result = try await provider.reply(to: .init(messages: [], text: "请只回复：连接成功", attachments: [], intent: nil))
                try Task.checkCancellation(); status = "已收到真实回答：" + String(result.text.prefix(100))
            } catch is CancellationError { status = "连接测试已停止。" }
            catch { status = error.localizedDescription }
        }
    }
}
