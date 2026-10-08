import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

// MARK: - GIF 生成错误

enum GIFGenerationError: LocalizedError {
    case invalidSource
    case frameExtractionFailed
    case encodingFailed
    case noFramesExtracted
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            return "无法读取视频文件，文件可能已损坏或格式不受支持"
        case .frameExtractionFailed:
            return "视频帧提取失败"
        case .encodingFailed:
            return "GIF 编码失败"
        case .noFramesExtracted:
            return "未能从视频中提取任何帧"
        case .unsupportedFormat:
            return "不支持的文件格式"
        }
    }
}

// MARK: - GIF 生成结果

struct GIFGenerationResult {
    let gifURL: URL
    let frameCount: Int
    let duration: TimeInterval
    let originalSize: Int64
    let gifSize: Int64
}

// MARK: - GIF 生成服务

struct GIFGenerationService {
    static let supportedFormats: [UTType] = [.mpeg4Movie, .quickTimeMovie, .avi, .movie, .gif]
    func videoDuration(of url: URL) -> TimeInterval { CMTimeGetSeconds(AVURLAsset(url: url).duration) }
    func generateGIF(from videoURL: URL, frameRate: Int, maxDimension: CGFloat, startTime: TimeInterval,
                     duration: TimeInterval, outputURL: URL, progressHandler: @escaping (Double, String) -> Void) throws -> GIFGenerationResult {
        guard videoURL.standardizedFileURL != outputURL.standardizedFileURL,
              (1...30).contains(frameRate), maxDimension.isFinite, (1...2048).contains(maxDimension),
              startTime.isFinite, startTime >= 0, duration.isFinite, duration > 0, duration <= 60 else { throw GIFGenerationError.invalidSource }
        let asset = AVURLAsset(url: videoURL)
        let total = CMTimeGetSeconds(asset.duration)
        guard total.isFinite, total > startTime else { throw GIFGenerationError.invalidSource }
        let length = min(duration, total - startTime)
        let count = max(1, Int(ceil(length * Double(frameRate))))
        let delay = length / Double(count)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        generator.requestedTimeToleranceBefore = CMTime(seconds: delay / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = generator.requestedTimeToleranceBefore
        defer { generator.cancelAllCGImageGeneration() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, count, nil) else { throw GIFGenerationError.encodingFailed }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        // 逐帧按时间顺序提取和编码，不保留整段未压缩帧，也不等待无法保证唤醒的信号量。
        for index in 0..<count {
            try Task.checkCancellation()
            try autoreleasepool {
                let time = CMTime(seconds: startTime + Double(index) * delay, preferredTimescale: 600)
                let frame = try generator.copyCGImage(at: time, actualTime: nil)
                CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
            progressHandler(Double(index + 1) / Double(count) * 0.95, "正在生成帧 \(index + 1)/\(count)")
        }
        try Task.checkCancellation()
        guard CGImageDestinationFinalize(destination) else { throw GIFGenerationError.encodingFailed }
        try (data as Data).write(to: outputURL, options: .atomic)
        progressHandler(1, "GIF 生成完成")
        return GIFGenerationResult(gifURL: outputURL, frameCount: count, duration: length,
            originalSize: FileUtils.fileSize(of: videoURL), gifSize: Int64(data.length))
    }
    func compressGIF(url: URL, maxDimension: CGFloat, frameSkip: Int, outputURL: URL,
                     progressHandler: @escaping (Double, String) -> Void) throws -> GIFGenerationResult {
        guard url.standardizedFileURL != outputURL.standardizedFileURL,
              maxDimension.isFinite, (1...2048).contains(maxDimension), frameSkip > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier else { throw GIFGenerationError.invalidSource }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw GIFGenerationError.noFramesExtracted }
        let skip = min(frameSkip, count)
        let selected = Array(stride(from: 0, to: count, by: skip))
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, selected.count, nil) else { throw GIFGenerationError.encodingFailed }
        if let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
           let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
           let loop = gif[kCGImagePropertyGIFLoopCount] {
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary)
        }
        var duration: Double = 0
        for (outputIndex, index) in selected.enumerated() {
            try Task.checkCancellation()
            var delay: Double = 0
            for sourceIndex in index..<min(index + skip, count) {
                let properties = CGImageSourceCopyPropertiesAtIndex(source, sourceIndex, nil) as? [CFString: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let value = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                    ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
                delay += value.isFinite && value > 0 ? value : 0.1
            }
            duration += delay
            try autoreleasepool {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension), kCGImageSourceCreateThumbnailWithTransform: true]
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { throw GIFGenerationError.frameExtractionFailed }
                CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
            progressHandler(Double(outputIndex + 1) / Double(selected.count) * 0.95, "正在处理 GIF 帧")
        }
        guard CGImageDestinationFinalize(destination) else { throw GIFGenerationError.encodingFailed }
        try (data as Data).write(to: outputURL, options: .atomic)
        progressHandler(1, "GIF 处理完成")
        return GIFGenerationResult(gifURL: outputURL, frameCount: selected.count, duration: duration,
            originalSize: FileUtils.fileSize(of: url), gifSize: Int64(data.length))
    }
}
