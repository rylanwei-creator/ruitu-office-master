#if os(macOS)
import SwiftUI

/// 首页 — 功能卡片总览
struct HomeView: View {
    @Binding var selectedNav: NavItem

    /// 卡片数据（工具类）
    private let toolCards: [(NavItem, String)] = [
        (.fileRename, "添加前缀/后缀、查找替换、序号命名"),
        (.imageProcessing, "压缩图片、调整尺寸"),
        (.formatConversion, "图片格式转换，输出格式按本机能力提供"),
        (.idPhoto, "人像换底、规格裁切、大小控制与打印排版"),
        (.pdfTools, "合并、拆分、加密、水印及基础文本转换"),
        (.videoCompression, "压缩视频文件，调节质量与分辨率"),
        (.mediaConversion, "本地语音转字幕、视频转 GIF 与 GIF 压缩"),
        (.ocr, "从图片中提取文字，支持中英文等多语言，纯本地离线识别"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // 页面标题
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        // Logo 图标
                        if let logoPath = AppResources.bundle.path(forResource: "Logo", ofType: "png"),
                           let nsImage = NSImage(contentsOfFile: logoPath) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 36, height: 36)
                        }
                        Text("锐途办公大师")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                    }
                    Text("一站式文件批量处理，让办公更高效")
                        .font(.system(size: 14))
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.top, 24)

                // 功能卡片区域
                VStack(alignment: .leading, spacing: 16) {
                    Text("全部工具")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 180, maximum: 230), spacing: 16)
                        ],
                        spacing: 16
                    ) {
                        ForEach(toolCards, id: \.0.id) { item, description in
                            FeatureCard(
                                title: item.rawValue,
                                description: description,
                                systemImage: item.systemImage
                            ) {
                                selectedNav = item
                            }
                        }
                    }
                }

                Spacer(minLength: 48)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 900)
        }
        .background(AppColors.background)
    }
}

#endif
