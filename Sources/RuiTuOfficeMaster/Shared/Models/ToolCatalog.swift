import Foundation

struct ToolCatalogEntry: Identifiable {
    let item: NavItem
    let description: String
    let keywords: String
    var id: String { item.rawValue }
    func matches(_ search: String) -> Bool {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        let text = item.rawValue + " " + description + " " + keywords
        return terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
}
enum ToolCatalog {
    static let tools: [ToolCatalogEntry] = [
        .init(item: .fileOrganizer, description: "按类型分类文件，预览路径、复制或移动及撤销", keywords: "文件夹 整理 归类 目录 folder organize"),
        .init(item: .fileRename, description: "添加前缀/后缀、查找替换、序号命名", keywords: "重命名 批量 文件名 rename"),
        .init(item: .imageProcessing, description: "压缩图片、调整尺寸与转换格式", keywords: "照片 缩小 大小 jpg png heic image"),
        .init(item: .formatConversion, description: "批量转换图片格式，保留透明区域", keywords: "jpg jpeg png heic bmp tiff webp"),
        .init(item: .cutout, description: "提取前景主体，导出透明背景 PNG", keywords: "抠图 去背景 移除背景 透明 cutout"),
        .init(item: .imageWatermark, description: "框选水印，周边或取样修补图片", keywords: "图片 照片 去水印 修复 擦除"),
        .init(item: .idPhoto, description: "人像换底、规格裁切、大小控制与打印排版", keywords: "一寸 二寸 蓝底 白底 红底 证照"),
        .init(item: .pdfTools, description: "合并、拆分、加密、水印及基础文本转换", keywords: "PDF Word doc docx 文档"),
        .init(item: .videoCompression, description: "压缩视频，调节质量与分辨率", keywords: "mp4 mov 影片 video"),
        .init(item: .mediaConversion, description: "本地语音转字幕、视频转 GIF 与 GIF 压缩", keywords: "录音 音频 逐字稿 转文字 srt gif 字幕"),
        .init(item: .ocr, description: "从图片和 PDF 中提取文字，在本机识别", keywords: "OCR 扫描 文字识别 文本"),
    ]
    static func search(_ text: String) -> [ToolCatalogEntry] { tools.filter { $0.matches(text) } }
}
