import Foundation

/// .app 使用 Contents/Resources 内的自带资源；SwiftPM 直接运行时使用生成的资源访问器。
enum AppResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("RuiTuOfficeMaster_RuiTuOfficeMaster.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
