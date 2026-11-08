import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import CryptoKit

enum ImageSizeGoal: Sendable, Equatable {
    case reduction(Double)
    case range(minimum: Int64, maximum: Int64)
    func bounds(original: Int64) throws -> (minimum: Int64, maximum: Int64) {
        switch self {
        case .reduction(let fraction):
            guard fraction.isFinite, fraction > 0, fraction < 1 else { throw TargetCompressionError.invalidRange }
            return (0, max(1, Int64((Double(original) * (1 - fraction)).rounded(.down))))
        case .range(let lower, let upper):
            guard lower > 0, upper >= lower, upper <= 1_000_000_000 else { throw TargetCompressionError.invalidRange }
            return (lower, upper)
        }
    }
}

struct ImageTargetOptions: Sendable {
    let goal: ImageSizeGoal
    let format: OutputFormat
    let qualityFloor: Double
    let maxDimension: CGFloat?
    let targetSize: CGSize?
    let fitWithin: CGSize?
    let allowResize: Bool
}

struct TargetImageData: Sendable {
    let data: Data
    let dimensions: CGSize
    let quality: Double
    let detail: String
    let targetMet: Bool
}

struct PreparedTargetImage: Sendable {
    let url: URL
    let sourceHash: String
    let outputHash: String
    let originalSize: Int64
    let byteCount: Int64
    let detail: String
    let targetMet: Bool
}

enum TargetCompressionError: LocalizedError {
    case invalidRange, noSmallerOutput, sourceChanged
    var errorDescription: String? {
        switch self {
        case .invalidRange: return "请输入有效的每张图片体积范围：大于 0，最小值不超过最大值，最大不超过 1000 MB"
        case .noSmallerOutput: return "当前格式、尺寸及最低质量无法生成比原图更小的文件。请允许等比缩小尺寸、降低最低质量或更改输出格式。"
        case .sourceChanged: return "原图片在试编码后已变化，请重新生成预估再处理"
        }
    }
}

/// Search encoded byte counts, never equate a codec quality value with a file-size ratio.
struct ImageTargetCompressor {
    static func hash(_ url: URL) throws -> String {
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func compress(_ url: URL, options: ImageTargetOptions) throws -> TargetImageData {
        try ImageCodec.validateStaticImage(at: url)
        guard options.qualityFloor.isFinite, (0.05...1).contains(options.qualityFloor) else { throw CompressionError.invalidQuality }
        let originalSize = FileUtils.fileSize(of: url)
        let bounds = try options.goal.bounds(original: originalSize)
        let ceiling = min(bounds.maximum, max(1, originalSize - 1))
        let type = try ImageCompressionService().outputType(for: options.format, originalURL: url)
        let originalType = try ImageCodec.sourceType(at: url)
        let originalDimensions = try ImageCodec.dimensions(at: url)
        let initialSize = try ImageCodec.outputSize(original: originalDimensions, maxDimension: options.maxDimension,
            targetSize: options.targetSize, fitWithin: options.fitWithin)
        if bounds.minimum > 0, originalSize >= bounds.minimum, originalSize <= bounds.maximum,
           initialSize == originalDimensions, type == originalType {
            return .init(data: try Data(contentsOf: url), dimensions: originalDimensions, quality: 1,
                detail: "达到体积目标 · 原图已在范围内，保留原文件内容 · \(Int(originalDimensions.width))×\(Int(originalDimensions.height)) px", targetMet: true)
        }
        let decoded = try ImageCodec.load(at: url, size: initialSize)
        let initialImage = try ImageCodec.render(decoded, size: initialSize, flattenAlpha: type == .jpeg || type == .bmp)
        let lossy = type != .png && type != .tiff && type != .bmp
        var smallest: (data: Data, size: CGSize, quality: Double)?
        var chosen: (data: Data, size: CGSize, quality: Double)?
        var bestBelowCeiling: (data: Data, size: CGSize, quality: Double)?
        var oversized: CGSize?, undersized: CGSize?
        var size = initialSize
        // Decode once. Bound work even for an impossible range or codec discontinuity.
        for _ in 0..<12 {
            try Task.checkCancellation()
            let image = size == initialSize ? initialImage : try ImageCodec.render(initialImage, size: size, flattenAlpha: type == .jpeg || type == .bmp)
            func encode(_ quality: Double) throws -> Data {
                try Task.checkCancellation()
                let data = try autoreleasepool { try ImageCodec.encode(image, type: type, quality: quality) }
                if smallest == nil || data.count < smallest!.data.count { smallest = (data, size, quality) }
                if data.count <= ceiling && (bestBelowCeiling == nil || data.count > bestBelowCeiling!.data.count) {
                    bestBelowCeiling = (data, size, quality)
                }
                return data
            }
            let full = try encode(1)
            if full.count <= ceiling {
                if full.count < bounds.minimum, options.allowResize, let larger = oversized,
                   larger.width - size.width > 1 || larger.height - size.height > 1 {
                    undersized = size
                    size = CGSize(width: max(1, floor((size.width + larger.width) / 2)), height: max(1, floor((size.height + larger.height) / 2)))
                    continue
                }
                chosen = (full, size, 1); break
            }
            var lowData = full
            if lossy {
                lowData = try encode(options.qualityFloor)
                if lowData.count <= ceiling {
                    var lo = options.qualityFloor, hi = 1.0
                    var best = (data: lowData, size: size, quality: lo)
                    for _ in 0..<8 {
                        let mid = (lo + hi) / 2, data = try encode(mid)
                        if data.count <= ceiling { lo = mid; best = (data, size, mid) } else { hi = mid }
                    }
                    // JPEG may jump sharply at quality 1.0. If all lower qualities
                    // undershoot a custom minimum, search between size brackets.
                    if best.data.count < bounds.minimum, options.allowResize, let larger = oversized,
                       larger.width - size.width > 1 || larger.height - size.height > 1 {
                        undersized = size
                        size = CGSize(width: max(1, floor((size.width + larger.width) / 2)), height: max(1, floor((size.height + larger.height) / 2)))
                        continue
                    }
                    chosen = best; break
                }
            }
            guard options.allowResize, max(size.width, size.height) > 1 else { break }
            oversized = size
            if let smaller = undersized {
                size = CGSize(width: max(1, floor((size.width + smaller.width) / 2)), height: max(1, floor((size.height + smaller.height) / 2)))
                continue
            }
            let factor = max(0.1, min(0.85, sqrt(Double(ceiling) / Double(lowData.count)) * 0.94))
            size = CGSize(width: max(1, floor(size.width * factor)), height: max(1, floor(size.height * factor)))
        }
        var keptOriginal = false
        if chosen == nil {
            if let bestBelowCeiling { chosen = bestBelowCeiling }
            else if let smallest, smallest.data.count < originalSize { chosen = smallest }
            else if initialSize == originalDimensions && type == originalType {
                chosen = (try Data(contentsOf: url), originalDimensions, 1); keptOriginal = true
            } else { throw TargetCompressionError.noSmallerOutput }
        }
        guard let chosen, chosen.data.count <= originalSize else { throw TargetCompressionError.noSmallerOutput }
        let met = chosen.data.count <= bounds.maximum && chosen.data.count >= bounds.minimum
        let resized = chosen.size != initialSize
        let sizeText = "\(Int(chosen.size.width))×\(Int(chosen.size.height)) px"
        let detail: String
        if keptOriginal { detail = "未达到目标：原图已较小，保留原文件内容 · \(sizeText)" }
        else if !met && chosen.data.count < bounds.minimum { detail = "低于目标范围：已使用最高可用质量，不为凑体积添加数据 · \(sizeText)" }
        else if !met { detail = "未达到目标：已输出可获得的较小文件，可允许缩小尺寸或降低最低质量 · \(sizeText)" }
        else { detail = "达到体积目标" + (resized ? " · 已等比缩小尺寸" : "") + " · \(sizeText)" }
        return TargetImageData(data: chosen.data, dimensions: chosen.size, quality: chosen.quality, detail: detail, targetMet: met && !keptOriginal)
    }
}

extension ImageCompressionWorker {
    func prepareTarget(url: URL, options: ImageTargetOptions, directory: URL) throws -> PreparedTargetImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            let hash = try ImageTargetCompressor.hash(url)
            let originalSize = FileUtils.fileSize(of: url)
            let result = try ImageTargetCompressor().compress(url, options: options)
            guard try ImageTargetCompressor.hash(url) == hash else { throw TargetCompressionError.sourceChanged }
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let type = try ImageCompressionService().outputType(for: options.format, originalURL: url)
            let output = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(type.preferredFilenameExtension ?? "png")
            try result.data.write(to: output, options: .atomic)
            return PreparedTargetImage(url: output, sourceHash: hash, outputHash: try ImageTargetCompressor.hash(output), originalSize: originalSize,
                byteCount: Int64(result.data.count), detail: result.detail, targetMet: result.targetMet)
        }
    }

    func exportTarget(url: URL, prepared: PreparedTargetImage, outputURL: URL) throws {
        try Task.checkCancellation()
        guard url.standardizedFileURL != outputURL.standardizedFileURL else { throw CompressionError.sameFile }
        guard try ImageTargetCompressor.hash(url) == prepared.sourceHash else { throw TargetCompressionError.sourceChanged }
        guard FileUtils.fileSize(of: prepared.url) == prepared.byteCount,
              prepared.byteCount <= prepared.originalSize,
              try ImageTargetCompressor.hash(prepared.url) == prepared.outputHash else { throw TargetCompressionError.sourceChanged }
        try FileManager.default.copyItem(at: prepared.url, to: outputURL)
    }
}
