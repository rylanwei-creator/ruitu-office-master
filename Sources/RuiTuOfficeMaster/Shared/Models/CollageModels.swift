import Foundation
import CoreGraphics

enum CollageMode: String, CaseIterable, Identifiable, Sendable {
    case grid = "布局拼图", vertical = "纵向长图", horizontal = "横向长图"
    var id: Self { self }
}
enum CollageRatio: String, CaseIterable, Identifiable, Sendable {
    case portrait = "3:4", square = "1:1", story = "9:16", photo = "2:3"
    case tall = "1:2", landscape = "4:3", camera = "3:2", wide = "16:9"
    var id: Self { self }
    var value: CGFloat {
        switch self {
        case .portrait: 3/4; case .square: 1; case .story: 9/16; case .photo: 2/3
        case .tall: 1/2; case .landscape: 4/3; case .camera: 3/2; case .wide: 16/9
        }
    }
}
enum CollageTemplate: String, CaseIterable, Identifiable, Sendable {
    case grid = "均匀网格", rows = "上下排列", columns = "左右排列"
    case left = "左侧大图", right = "右侧大图", top = "上方大图", bottom = "下方大图", mosaic = "错落排布"
    var id: Self { self }
    /// Top-left origin, normalized coordinates. The same geometry drives icons, preview and export.
    func cells(count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        if count == 1 { return [CGRect(x: 0, y: 0, width: 1, height: 1)] }
        func strips(_ count: Int, horizontal: Bool, in box: CGRect) -> [CGRect] {
            (0..<count).map { i in
                horizontal
                ? CGRect(x: box.minX + CGFloat(i) * box.width / CGFloat(count), y: box.minY, width: box.width / CGFloat(count), height: box.height)
                : CGRect(x: box.minX, y: box.minY + CGFloat(i) * box.height / CGFloat(count), width: box.width, height: box.height / CGFloat(count))
            }
        }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        switch self {
        case .rows: return strips(count, horizontal: false, in: unit)
        case .columns: return strips(count, horizontal: true, in: unit)
        case .left, .right:
            let hero = CGRect(x: self == .left ? 0 : 0.4, y: 0, width: 0.6, height: 1)
            let rest = CGRect(x: self == .left ? 0.6 : 0, y: 0, width: 0.4, height: 1)
            return [hero] + strips(count - 1, horizontal: false, in: rest)
        case .top, .bottom:
            let hero = CGRect(x: 0, y: self == .top ? 0 : 0.4, width: 1, height: 0.6)
            let rest = CGRect(x: 0, y: self == .top ? 0.6 : 0, width: 1, height: 0.4)
            return [hero] + strips(count - 1, horizontal: true, in: rest)
        case .grid, .mosaic:
            let rows = Int(ceil(sqrt(Double(count))))
            var result: [CGRect] = []; var remaining = count
            for row in 0..<rows {
                let n = Int(ceil(Double(remaining) / Double(rows - row)))
                let boxes = strips(n, horizontal: true, in: CGRect(x: 0, y: CGFloat(row) / CGFloat(rows), width: 1, height: 1 / CGFloat(rows)))
                if self == .mosaic && n > 1 {
                    let weight: CGFloat = row.isMultiple(of: 2) ? 0.6 : 0.4
                    result += [CGRect(x: 0, y: CGFloat(row)/CGFloat(rows), width: weight, height: 1/CGFloat(rows))]
                    result += strips(n - 1, horizontal: true, in: CGRect(x: weight, y: CGFloat(row)/CGFloat(rows), width: 1-weight, height: 1/CGFloat(rows)))
                } else { result += boxes }
                remaining -= n
            }
            return result
        }
    }
}
enum CollageBackground: String, CaseIterable, Identifiable, Sendable {
    case white = "白色", cream = "奶油", black = "黑色", blue = "浅蓝", transparent = "透明"
    var id: Self { self }
    var rgba: (CGFloat, CGFloat, CGFloat, CGFloat) {
        switch self {
        case .white: (1,1,1,1); case .cream: (0.97,0.94,0.88,1)
        case .black: (0.08,0.08,0.08,1); case .blue: (0.87,0.94,0.99,1); case .transparent: (0,0,0,0)
        }
    }
}
enum CollageFilter: String, CaseIterable, Identifiable, Sendable {
    case original = "原图", mono = "黑白", warm = "暖色", cool = "冷色"
    var id: Self { self }
}
enum CollageFormat: String, CaseIterable, Identifiable, Sendable {
    case png = "PNG", jpeg = "JPG"
    var id: Self { self }
    var fileExtension: String { self == .png ? "png" : "jpg" }
}
struct CollageSettings: Equatable, Sendable {
    var mode: CollageMode = .grid
    var ratio: CollageRatio = .portrait
    var template: CollageTemplate = .grid
    var spacing: Double = 12
    var margin: Double = 24
    var background: CollageBackground = .white
    var fitImages = false
    /// Grid: canvas width; vertical/horizontal: shared image width/height before safety scaling.
    var resolution: Double = 2400
    var filter: CollageFilter = .original
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var caption = ""
    var captionAtTop = false
    var captionSize: Double = 64
    var format: CollageFormat = .png
    var jpegQuality: Double = 0.9
}
struct CollagePhoto: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let size: CGSize
    let thumbnail: CGImage
    var zoom: Double = 1
    var panX: Double = 0
    var panY: Double = 0
    init(id: UUID = UUID(), url: URL, size: CGSize, thumbnail: CGImage) {
        self.id = id; self.url = url; self.size = size; self.thumbnail = thumbnail
    }
}
struct CollageGeometry {
    let size: CGSize
    let cells: [CGRect]
    let reduced: Bool
}
enum CollageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}
