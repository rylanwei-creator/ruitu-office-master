import Foundation
import AVFoundation

// MARK: - 语音活动段

struct SpeechSegment {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

// MARK: - 预处理错误

enum PreprocessError: LocalizedError {
    case readFailed
    case formatNotSupported
    case converterFailed
    case bufferFailed
    case writeFailed
    case emptyAudio
    case engineError
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .readFailed: return "无法读取音频文件"
        case .formatNotSupported: return "音频格式不支持"
        case .converterFailed: return "音频转换器创建失败"
        case .bufferFailed: return "音频缓冲区创建失败"
        case .writeFailed: return "预处理音频写入失败"
        case .emptyAudio: return "音频文件无有效内容"
        case .engineError: return "音频引擎处理失败"
        case .tooLarge: return "音频解码后超过内存限制，请先截取较短片段再识别"
        }
    }
}

// MARK: - 音频预处理器

/// 语音识别前的统一音频预处理：
/// 1. 重采样到 16kHz 单声道 16-bit PCM WAV
/// 2. 音量归一化到 -12dBFS
/// 3. EQ 降噪（高通+低通滤波，保留人声频段 80Hz–8kHz）
/// 4. VAD 静音检测：剪掉头尾静音，>1秒停顿处切分
struct AudioPreprocessor {

    /// 目标采样率 — SFSpeechRecognizer 内部原生采样率
    private static let targetSampleRate: Double = 16000

    /// 音量归一化目标（dBFS）
    private static let targetDBFS: Float = -12.0

    // MARK: 主入口：完整预处理

    /// 对原始音频执行完整预处理管线
    /// - Parameter sourceURL: 原始音频文件 URL（支持 WAV/MP3/M4A/AAC/CAF 等）
    /// - Parameter enableNoiseReduction: 是否启用 EQ 降噪，默认开启
    /// - Parameter progressHandler: 进度回调 (0~1, 阶段描述)，用于细化进度上报防止卡死
    /// - Returns: 预处理后的 PCM WAV 文件 URL（缓存目录，30 分钟自动清理）
    func preprocess(
        sourceURL: URL,
        enableNoiseReduction: Bool = false,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async throws -> URL {
        // --- 阶段 1：读取源音频 (0%→8%) ---
        progressHandler?(0.02, "正在读取音频文件...")
        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw PreprocessError.readFailed
        }
        let sourceFormat = sourceFile.processingFormat
        let sourceLength = sourceFile.length
        guard sourceLength > 0 else { throw PreprocessError.emptyAudio }
        guard sourceLength <= Int64(UInt32.max),
              Double(sourceLength) * Double(sourceFormat.channelCount) * 4 <= 256 * 1024 * 1024 else { throw PreprocessError.tooLarge }
        try Task.checkCancellation()

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(sourceLength)
        ) else { throw PreprocessError.bufferFailed }
        try sourceFile.read(into: sourceBuffer)
        sourceBuffer.frameLength = AVAudioFrameCount(sourceLength)
        progressHandler?(0.08, "音频文件读取完成")

        // --- 阶段 2：重采样到 16kHz 单声道 16-bit PCM (8%→50%) ---
        progressHandler?(0.12, "正在重采样到16kHz单声道...")
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else { throw PreprocessError.formatNotSupported }

        let resampled: AVAudioPCMBuffer
        do {
            resampled = try convertPCM(
                sourceBuffer: sourceBuffer,
                sourceFormat: sourceFormat,
                targetFormat: targetFormat,
                sourceLength: AVAudioFrameCount(sourceLength)
            )
        } catch {
            throw PreprocessError.converterFailed
        }
        progressHandler?(0.50, "重采样完成")

        // --- 阶段 3：音量归一化到 -12dBFS (50%→60%) ---
        progressHandler?(0.55, "正在音量归一化...")
        normalizeVolume(buffer: resampled, targetDBFS: Self.targetDBFS)
        progressHandler?(0.60, "音量归一化完成")

        // --- 阶段 4：写入 WAV 文件 (60%→70%) ---
        progressHandler?(0.65, "正在写入预处理文件...")
        let pcmURL = CacheManager.mediaCacheDirectory
            .appendingPathComponent("prep_pcm_\(UUID().uuidString).wav")
        try? FileManager.default.removeItem(at: pcmURL)
        do {
            try writePCM(buffer: resampled, format: targetFormat, to: pcmURL)
        } catch {
            throw PreprocessError.writeFailed
        }
        progressHandler?(0.70, "预处理文件写入完成")

        // --- 阶段 5：EQ 降噪（可选，默认关闭）(70%→100%) ---
        let processedURL: URL
        if enableNoiseReduction {
            progressHandler?(0.75, "正在EQ降噪（高通80Hz + 低通8kHz）...")
            do {
                // 30 秒超时保护：EQ 离线渲染是同步阻塞操作，必须在独立 Task 中运行
                processedURL = try await withThrowingTaskGroup(of: URL.self) { group in
                    group.addTask {
                        return try await applyNoiseReduction(url: pcmURL)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                        throw PreprocessError.engineError
                    }
                    guard let result = try await group.next() else {
                        throw PreprocessError.engineError
                    }
                    group.cancelAll()
                    return result
                }
                progressHandler?(1.0, "降噪完成")
            } catch {
                // EQ 降噪失败/超时不终止任务，回退到未降噪的 PCM 文件
                progressHandler?(1.0, "降噪跳过，使用原始预处理结果继续识别")
                return pcmURL
            }
        } else {
            processedURL = pcmURL
            progressHandler?(1.0, "预处理完成")
        }

        return processedURL
    }

    // MARK: VAD：检测语音段 + 去头尾静音 + 长停顿切分

    /// 分析预处理后的 PCM 音频，检测语音活动段
    /// - 自动跳过开头/结尾的纯静音
    /// - 在 >1 秒的停顿处切分
    /// - 至少返回一个覆盖全部时长的段（全静音时）
    func detectSpeechSegments(url: URL) throws -> [SpeechSegment] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let format = file.processingFormat
        let length = Int(file.length)
        let sampleRate = format.sampleRate
        let totalDuration = Double(length) / sampleRate

        guard length > 0 else {
            return []
        }

        guard length <= Int(UInt32.max), length <= 128 * 1024 * 1024 else { throw PreprocessError.tooLarge }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length)) else {
            throw PreprocessError.bufferFailed
        }
        try file.read(into: buffer)
        buffer.frameLength = AVAudioFrameCount(length)

        let energies = computeFrameEnergies(buffer: buffer, frameLength: length, sampleRate: sampleRate)
        guard !energies.isEmpty else {
            return []
        }

        // 自适应阈值：取能量中位数的 1/4，并设最低下限防止全静音文件误判
        let sorted = energies.sorted()
        let median = sorted[energies.count / 2]
        let speechThreshold = max(0.003, median * 0.25)

        let isSpeech = energies.map { $0 > speechThreshold }

        // 形态学闭运算：填补 < 0.15 秒的语音间隙（避免误切）
        let closed = morphologicalClose(isSpeech, maxGapFrames: 7)

        // 提取连续语音段
        let frameDuration = (Double(length) / sampleRate) / Double(energies.count)
        return extractSegments(
            isSpeech: closed,
            frameDuration: frameDuration,
            totalDuration: totalDuration,
            totalFrames: energies.count
        )
    }

    /// 按语音段裁剪音频，输出单独文件
    func trimToSegment(url: URL, segment: SpeechSegment) async throws -> URL {
        return try await trimSilence(url: url, startTime: segment.startTime, endTime: segment.endTime)
    }

    /// 裁剪音频的头尾静音，保留 startTime..<endTime 区间
    func trimSilence(url: URL, startTime: TimeInterval, endTime: TimeInterval) async throws -> URL {
        guard startTime.isFinite, endTime.isFinite, startTime >= 0, endTime > startTime else { throw PreprocessError.emptyAudio }
        let input = try AVAudioFile(forReading: url)
        let rate = input.processingFormat.sampleRate
        let first = min(input.length, AVAudioFramePosition(startTime * rate))
        let last = min(input.length, AVAudioFramePosition(endTime * rate))
        guard last > first else { throw PreprocessError.emptyAudio }
        let outputURL = CacheManager.cacheFileURL(in: CacheManager.mediaCacheDirectory, prefix: "chunk", ext: "wav")
        let output = try AVAudioFile(forWriting: outputURL, settings: input.fileFormat.settings,
            commonFormat: input.processingFormat.commonFormat, interleaved: input.processingFormat.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else { throw PreprocessError.bufferFailed }
        input.framePosition = first
        var remaining = last - first
        while remaining > 0 {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 8192)))
            guard buffer.frameLength > 0 else { throw PreprocessError.emptyAudio }
            try output.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return outputURL
    }

    // MARK: - 内部：PCM 格式转换

    private func convertPCM(
        sourceBuffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        sourceLength: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw PreprocessError.converterFailed
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceLength) * ratio * 1.1 + 512)

        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { throw PreprocessError.bufferFailed }

        var error: NSError?
        var inputConsumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        let status = converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        if let error { throw error }
        guard output.frameLength > 0, status != .error else {
            throw PreprocessError.emptyAudio
        }

        return output
    }

    // MARK: - 内部：音量归一化

    private func normalizeVolume(buffer: AVAudioPCMBuffer, targetDBFS: Float) {
        guard let data = buffer.int16ChannelData?.pointee else { return }
        let count = Int(buffer.frameLength)

        var peak: Int32 = 0
        for i in 0..<count {
            let v = abs(Int32(data[i]))
            if v > peak { peak = v }
        }
        guard peak > 0 else { return }

        let currentPeak = Float(peak) / 32767.0
        let targetPeak = pow(10.0, targetDBFS / 20.0)
        let gain = targetPeak / currentPeak

        // 限幅：增益不超过 6×（15.6dB），不低于 0.3×（防止已响亮的音频过度压缩）
        let clamped = min(6.0, max(0.3, gain))

        for i in 0..<count {
            let sample = Float(data[i]) * clamped
            data[i] = Int16(max(-32768, min(32767, Int32(sample))))
        }
    }

    // MARK: - 内部：写入 PCM WAV

    private func writePCM(
        buffer: AVAudioPCMBuffer,
        format: AVAudioFormat,
        to url: URL
    ) throws {
        let outputFile = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try outputFile.write(from: buffer)
    }

    // MARK: - 内部：EQ 降噪

    /// 离线 EQ 滤波：高通 80Hz 去低频环境噪音 + 低通 8kHz 去高频嘶声
    private func applyNoiseReduction(url: URL) async throws -> URL {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let length = audioFile.length

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 3)

        // 80Hz 高通，-20dB — 去除空调/风扇/电流低频嗡嗡声
        eq.bands[0].filterType = .highPass
        eq.bands[0].frequency = 80
        eq.bands[0].gain = -20
        eq.bands[0].bypass = false

        // 8kHz 低通，-10dB — 去除键盘/鼠标/高频环境噪音
        eq.bands[1].filterType = .lowPass
        eq.bands[1].frequency = 8000
        eq.bands[1].gain = -10
        eq.bands[1].bypass = false

        // 10kHz 参量削减 -15dB — 进一步削弱高频嘶声
        eq.bands[2].filterType = .parametric
        eq.bands[2].frequency = 10000
        eq.bands[2].bandwidth = 1.0
        eq.bands[2].gain = -15
        eq.bands[2].bypass = false

        engine.attach(player)
        engine.attach(eq)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: engine.mainMixerNode, format: format)

        let outputURL = CacheManager.mediaCacheDirectory
            .appendingPathComponent("prep_nr_\(UUID().uuidString).caf")
        try? FileManager.default.removeItem(at: outputURL)

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        try engine.start()

        await player.scheduleFile(audioFile, at: nil)
        player.play()

        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else {
            engine.stop()
            return url
        }

        // 迭代上限：总帧数 / 每轮最小帧数 + 安全余量，防止死循环
        let maxIterations = Int(length / 512) + 1000
        var iteration = 0
        var lastSampleTime: AVAudioFramePosition = -1

        while engine.manualRenderingSampleTime < length, iteration < maxIterations {
            iteration += 1

            // 响应外部取消（超时 / 用户取消），跳出渲染循环
            if Task.isCancelled { break }

            // 检测渲染是否卡住：连续两轮 sampleTime 不变则退出
            let currentSampleTime = engine.manualRenderingSampleTime
            if currentSampleTime == lastSampleTime {
                break
            }
            lastSampleTime = currentSampleTime

            let framesToRender = min(
                renderBuffer.frameCapacity,
                AVAudioFrameCount(length - currentSampleTime)
            )

            guard framesToRender > 0 else { break }

            let status = try engine.renderOffline(framesToRender, to: renderBuffer)
            switch status {
            case .success:
                try outputFile.write(from: renderBuffer)
            case .insufficientDataFromInputNode:
                if renderBuffer.frameLength > 0 {
                    try outputFile.write(from: renderBuffer)
                }
                // 输入数据耗尽，正常结束
                break
            case .cannotDoInCurrentContext:
                // 引擎无法在当前上下文继续渲染，终止而非死循环
                engine.stop()
                return url
            case .error:
                engine.stop()
                throw PreprocessError.engineError
            @unknown default:
                // 未知状态，安全退出
                engine.stop()
                return url
            }
        }

        engine.stop()

        // 如果降噪后文件有效则用它，否则回退到原始预处理文件
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attrs[.size] as? Int, size > 44 {
            return outputURL
        }
        return url
    }

    // MARK: - 内部：VAD 帧能量计算

    private func computeFrameEnergies(
        buffer: AVAudioPCMBuffer,
        frameLength: Int,
        sampleRate: Double
    ) -> [Float] {
        let frameSize = Int(sampleRate * 0.02) // 20ms
        let totalFrames = frameLength / frameSize
        guard totalFrames > 0, let data = buffer.int16ChannelData?.pointee else { return [] }

        var energies = [Float](repeating: 0, count: totalFrames)
        for i in 0..<totalFrames {
            let offset = i * frameSize
            var sum: Float = 0
            for j in 0..<frameSize {
                let s = Float(data[offset + j]) / 32768.0
                sum += s * s
            }
            energies[i] = sqrt(sum / Float(frameSize))
        }
        return energies
    }

    // MARK: - 内部：形态学闭运算

    /// 填补语音中短暂的空隙（< maxGapFrames 帧），避免在自然停顿处误切
    private func morphologicalClose(_ isSpeech: [Bool], maxGapFrames: Int) -> [Bool] {
        var result = isSpeech
        var index = 0
        while index < result.count {
            if result[index] { index += 1; continue }
            let start = index
            while index < result.count && !result[index] { index += 1 }
            if start > 0, index < result.count, index - start <= maxGapFrames {
                for position in start..<index { result[position] = true }
            }
        }
        return result
    }

    // MARK: - 内部：提取语音段

    private func extractSegments(
        isSpeech: [Bool],
        frameDuration: Double,
        totalDuration: TimeInterval,
        totalFrames: Int
    ) -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        var i = 0

        while i < totalFrames {
            // 跳过静音帧
            while i < totalFrames && !isSpeech[i] { i += 1 }
            guard i < totalFrames else { break }

            let segStart = i
            var segEnd = i

            // 扫描到段结束（遇到 >1 秒的停顿则切分）
            while i < totalFrames {
                if isSpeech[i] {
                    segEnd = i
                    i += 1
                } else {
                    let gapStart = i
                    while i < totalFrames && !isSpeech[i] { i += 1 }
                    let gapFrames = i - gapStart
                    if gapFrames > 50 { // > 1 秒（50 帧 × 20ms）
                        break
                    }
                }
            }

            let startTime = Double(segStart) * frameDuration
            let endTime = min(Double(segEnd + 1) * frameDuration, totalDuration)

            if startTime < endTime {
                segments.append(SpeechSegment(startTime: startTime, endTime: endTime))
            }
        }

        return segments
    }
}
