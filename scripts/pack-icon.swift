import Foundation
import CoreGraphics
import ImageIO

// 16/32px 使用系统支持的预乘 ARGB 图块，其余标准尺寸保留 PNG 数据。
let iconset = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let entries: [(String, String, Int)] = [
    ("ic04", "icon_16x16.png", 16), ("ic11", "icon_16x16@2x.png", 32),
    ("ic05", "icon_32x32.png", 32), ("ic12", "icon_32x32@2x.png", 64),
    ("ic07", "icon_128x128.png", 128), ("ic13", "icon_128x128@2x.png", 256),
    ("ic08", "icon_256x256.png", 256), ("ic14", "icon_256x256@2x.png", 512),
    ("ic09", "icon_512x512.png", 512), ("ic10", "icon_512x512@2x.png", 1024)
]
func uint32(_ value: Int) -> Data {
    let n = UInt32(value)
    return Data([UInt8((n >> 24) & 255), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
}
func argb(_ image: CGImage, size: Int) -> Data {
    let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    context.setBlendMode(.copy)
    context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    var encoded = Data("ARGB".utf8)
    for component in [3, 0, 1, 2] {
        var start = 0
        while start < size * size {
            let count = min(128, size * size - start)
            encoded.append(UInt8(count - 1))
            for index in start..<(start + count) { encoded.append(pixels[index * 4 + component]) }
            start += count
        }
    }
    return encoded
}
var body = Data()
for (type, name, size) in entries {
    let file = iconset.appendingPathComponent(name)
    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width == size, image.height == size else {
        fatalError("Invalid icon image: \(name)")
    }
    let data = type == "ic04" || type == "ic05" ? argb(image, size: size) : try Data(contentsOf: file)
    body.append(Data(type.utf8)); body.append(uint32(data.count + 8)); body.append(data)
}
var icon = Data("icns".utf8)
icon.append(uint32(body.count + 8)); icon.append(body)
try icon.write(to: output, options: .atomic)
