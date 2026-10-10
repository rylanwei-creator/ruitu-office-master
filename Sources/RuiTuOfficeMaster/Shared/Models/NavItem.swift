import SwiftUI

/// 导航项枚举 — 定义侧边栏所有可导航的页面
enum NavItem: String, CaseIterable, Identifiable {
    case home = "首页"
    case fileRename = "文件改名"
    case fileOrganizer = "文件整理"
    case imageProcessing = "图片处理"
    case cutout = "抠图"
    case imageWatermark = "图片去水印"
    case idPhoto = "证件照"
    case pdfTools = "PDF 工具"
    case formatConversion = "格式转换"
    case videoCompression = "视频压缩"
    case mediaConversion = "音视频转换"
    case ocr = "OCR 文字识别"
    case tasks = "任务中心"
    case history = "历史记录"
    case settings = "设置"

    var id: String { rawValue }

    /// SF Symbols 图标名
    var systemImage: String {
        switch self {
        case .home: return "house"
        case .fileRename: return "pencil"
        case .fileOrganizer: return "folder.badge.gearshape"
        case .imageProcessing: return "photo"
        case .cutout: return "person.crop.rectangle.badge.plus"
        case .imageWatermark: return "eraser"
        case .idPhoto: return "person.crop.rectangle"
        case .pdfTools: return "doc.on.doc"
        case .formatConversion: return "photo.stack"
        case .videoCompression: return "video"
        case .mediaConversion: return "waveform"
        case .ocr: return "text.viewfinder"
        case .tasks: return "list.bullet.clipboard"
        case .history: return "clock"
        case .settings: return "gear"
        }
    }

    /// 分组（用于侧边栏分隔）
    var isUtility: Bool {
        self == .tasks || self == .history || self == .settings
    }
}
