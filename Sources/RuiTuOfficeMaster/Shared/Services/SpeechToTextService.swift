import Foundation
import Speech
import AVFoundation
import NaturalLanguage
import UniformTypeIdentifiers
#if canImport(Translation)
import Translation
#endif

// MARK: - 识别任务引用（突破 struct 不可变性，允许外部安全取消）

/// 所有完成路径（正常、错误、取消、超时）共享一次性完成门闩。
private final class RecognitionSession: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<TranscriptionResult, Error>?
    private var pending: Result<TranscriptionResult, Error>?
    private var task: SFSpeechRecognitionTask?
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func install(_ c: CheckedContinuation<TranscriptionResult, Error>) {
        lock.lock()
        if let result = pending { pending = nil; lock.unlock(); c.resume(with: result) }
        else { continuation = c; lock.unlock() }
    }
    func attach(_ task: SFSpeechRecognitionTask) {
        lock.lock()
        if finished { lock.unlock(); task.cancel() }
        else { self.task = task; lock.unlock() }
    }
    func finish(_ result: Result<TranscriptionResult, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil; task = nil
        if c == nil { pending = result }
        lock.unlock()
        c?.resume(with: result)
    }
    func cancel() {
        lock.lock(); let current = task; lock.unlock()
        finish(.failure(SpeechToTextError.cancelled))
        current?.cancel()
    }
}
private final class TaskRef: @unchecked Sendable {
    private let lock = NSLock()
    private var session: RecognitionSession?
    func set(_ value: RecognitionSession) { lock.lock(); session = value; lock.unlock() }
    func clear(_ value: RecognitionSession) { lock.lock(); if session === value { session = nil }; lock.unlock() }
    func cancel() { lock.lock(); let current = session; lock.unlock(); current?.cancel() }
}

// MARK: - 字幕条目

struct SubtitleEntry: Identifiable {
    let id = UUID()
    var index: Int
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var translatedText: String?
}

// MARK: - 字幕导出格式

enum SubtitleExportFormat: String, CaseIterable {
    case srt = "SRT"
    case vtt = "VTT"
    case txt = "TXT"
    case plainText = "纯文本"
}

// MARK: - 转录结果

struct TranscriptionResult {
    let entries: [SubtitleEntry]
    let fullText: String
    let detectedLanguage: String?
    let confidence: Float
}

// MARK: - 语音转文字错误

enum SpeechToTextError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case noSpeechDetected
    case audioExtractionFailed
    case exportFailed
    case cancelled
    case preprocessingFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "语音识别未授权，请打开 系统设置 > 隐私与安全性 > 语音识别，授权本 App 后重试"
        case .recognizerUnavailable:
            return "该语言的本地语音识别不可用，请检查系统语言资源，或改用其他语言；不会回退到云端识别"
        case .noSpeechDetected:
            return "文件中未检测到语音内容"
        case .audioExtractionFailed:
            return "从视频中提取音频失败"
        case .exportFailed:
            return "字幕文件导出失败"
        case .cancelled:
            return "处理已取消"
        case .preprocessingFailed(let reason):
            return "音频预处理失败：\(reason)，请更换文件重试"
        }
    }
}

// MARK: - 语音转文字服务

struct SpeechToTextService {

    // MARK: 取消控制

    private let taskRef = TaskRef()

    /// 取消当前正在执行的语音识别任务（线程安全，可从任意线程调用）
    func cancelRecognition() { taskRef.cancel() }

    // MARK: 芯片适配

    /// EQ 降噪默认关闭。
    /// AVAudioEngine 离线渲染在处理长音频时会长时间阻塞，且 SFSpeechRecognizer 自带降噪能力，
    /// 开启 EQ 的收益远小于卡死风险。如需开启，改为 `return true`。
    private static var enableNoiseReduction: Bool {
        return false
    }

    /// 识别超时时间（纳秒）— Intel 10 分钟，M 芯片 5 分钟
    private static var recognitionTimeout: UInt64 {
        #if arch(arm64)
        return 300_000_000_000 // M芯片: 5分钟
        #else
        return 600_000_000_000 // Intel芯片: 10分钟
        #endif
    }

    /// 是否强制本地识别 — Intel 强制本地（降低 CPU 负载），M 芯片可用服务器级识别
    private static var requiresOnDeviceRecognition: Bool { true }

    /// 识别任务提示 — Intel 用 .search（轻量），M 芯片用 .dictation（高精度）
    private static var recognitionTaskHint: SFSpeechRecognitionTaskHint {
        #if arch(arm64)
        return .dictation
        #else
        return .search
        #endif
    }

    // MARK: 支持格式

    static let audioFormats: [UTType] = {
        var types: [UTType] = [.wav, .aiff]
        if let mp3 = UTType(filenameExtension: "mp3") { types.append(mp3) }
        if let m4a = UTType(filenameExtension: "m4a") { types.append(m4a) }
        if let aac = UTType(filenameExtension: "aac") { types.append(aac) }
        if let flac = UTType(filenameExtension: "flac") { types.append(flac) }
        if let caf = UTType(filenameExtension: "caf") { types.append(caf) }
        return types
    }()

    static let videoFormats: [UTType] = [.mpeg4Movie, .quickTimeMovie, .avi, .movie]

    static let supportedFormats: [UTType] = audioFormats + videoFormats

    // MARK: 支持的语言

    static var supportedLanguages: [(code: String, name: String)] {
        let locales = SFSpeechRecognizer.supportedLocales()
        return locales.map { locale in
            let code = locale.identifier
            let name = locale.localizedString(forIdentifier: code) ?? code
            return (code: code, name: name)
        }.sorted { $0.name < $1.name }
    }

    // 工具方法：文件大小相关已统一收拢到 FileUtils

    // MARK: 音频提取（视频 → 临时 M4A）

    private func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard asset.tracks(withMediaType: .audio).first != nil else {
            throw SpeechToTextError.noSpeechDetected
        }

        let outputURL = CacheManager.mediaCacheDirectory
            .appendingPathComponent("stt_audio_\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: outputURL)

        // 使用 AVAssetExportSession 替代 AVAssetReader/Writer：避免竞态条件，
        // 后者 requestMediaDataWhenReady 异步执行与 finishWriting 之间存在竞态，
        // 可能导致提取出空音频文件
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw SpeechToTextError.audioExtractionFailed
        }

        session.outputURL = outputURL
        session.outputFileType = .m4a

        // 异步等待导出完成，避免阻塞 Swift 并发线程池
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously {
                c.resume()
            }
        }

        if let error = session.error {
            throw error
        }
        guard session.status == .completed else {
            throw SpeechToTextError.audioExtractionFailed
        }

        return outputURL
    }

    // MARK: 智能断句合并

    /// 将识别器返回的细粒度片段智能合并为自然通顺的长字幕
    ///
    /// SFSpeechRecognizer 每个 segment 通常只包含 1~2 个词，
    /// 直接逐段导出会导致字幕碎片化。本方法按以下规则合并：
    ///
    /// **切割条件（满足任一即切）**：
    /// 1. 上一段以强标点结尾（。！？.!?）— 语句自然结束
    /// 2. 当前批次累积超过 4 秒 — 避免单条字幕过长
    /// 3. 两段之间间隔 > 0.5 秒 — 明显停顿，换句
    /// 4. 批次 ≥ 2 秒 + 弱标点或小停顿 — 句子够长且有自然断点
    ///
    /// **保证**：
    /// - 单条字幕 2~5 秒，完整显示一个自然句
    /// - 不会出现单字、单词独占一行
    /// - 时间轴与原始识别结果保持对齐
    private func mergeSegments(
        _ segments: [SFTranscriptionSegment],
        totalDuration: TimeInterval
    ) -> [SubtitleEntry] {
        guard !segments.isEmpty else { return [] }

        let strongPunct = Set<Character>("。！？.!?")
        let weakPunct = Set<Character>("，,；;：:、")

        var entries: [SubtitleEntry] = []
        var batchStart = 0

        for endIdx in 1...segments.count {
            let isLast = endIdx == segments.count

            let shouldFinalize: Bool
            if isLast {
                shouldFinalize = true
            } else {
                let prev = segments[endIdx - 1]
                let curr = segments[endIdx]

                // 两段之间的间隔（秒）
                let gap = (curr.timestamp - curr.duration) - prev.timestamp

                // 当前批次已累积的时长（秒）
                let batchStartTime = segments[batchStart].timestamp - segments[batchStart].duration
                let batchDuration = prev.timestamp - batchStartTime

                // 上一段末尾字符
                let lastChar = prev.substring.last ?? Character(" ")

                shouldFinalize =
                    strongPunct.contains(lastChar) ||
                    batchDuration >= 4.0 ||
                    gap > 0.5 ||
                    (batchDuration >= 2.0 && (weakPunct.contains(lastChar) || gap > 0.3))
            }

            if shouldFinalize {
                let batch = segments[batchStart..<endIdx]

                // 拼接文本（中文无需空格，直接拼接；英文片段自带前后空格）
                var text = batch.map { $0.substring }.joined()
                text = text
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let firstSeg = segments[batchStart]
                let lastSeg = segments[endIdx - 1]

                entries.append(SubtitleEntry(
                    index: entries.count + 1,
                    startTime: max(0, firstSeg.timestamp - firstSeg.duration),
                    endTime: lastSeg.timestamp,
                    text: text
                ))

                batchStart = endIdx
            }
        }

        return entries
    }

    // MARK: 语音转文字（文件级）

    /// 对音频/视频文件执行离线语音识别
    /// - Parameters:
    ///   - url: 音频或视频文件 URL
    ///   - language: 识别语言 BCP-47 代码（如 "zh-CN"），nil 则为自动检测
    ///   - hotwords: 自定义热词列表，识别时优先匹配（如人名、术语、产品名）
    ///   - progressHandler: 进度回调 (进度0~1, 状态描述)
    /// - Throws: SpeechToTextError.cancelled 当超时或外部取消时
    func transcribe(
        url: URL,
        language: String? = nil,
        hotwords: [String] = [],
        progressHandler: @escaping (Double, String) -> Void
    ) async throws -> TranscriptionResult {
        // 检查权限
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in c.resume() }
            }
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            throw SpeechToTextError.notAuthorized
        }

        // 检查取消（入口处）
        try Task.checkCancellation()

        // 阶段 1：从视频提取音频（0%→8%）
        let ext = url.pathExtension.lowercased()
        let videoExts = ["mp4", "mov", "avi", "m4v", "mkv"]
        let rawAudioURL: URL
        if videoExts.contains(ext) {
            progressHandler(0.02, "正在从视频中提取音频...")
            try Task.checkCancellation()
            rawAudioURL = try await extractAudio(from: url)
            progressHandler(0.08, "音频提取完成")
        } else {
            rawAudioURL = url
        }

        // 阶段 2：音频预处理（8%→25%）
        // 预处理内部拆分 5 个子阶段，通过 progressHandler 细化上报，避免进度条卡死
        progressHandler(0.09, "开始音频预处理...")
        try Task.checkCancellation()
        let preprocessor = AudioPreprocessor()
        let cleanURL: URL
        do {
            cleanURL = try await preprocessor.preprocess(
                sourceURL: rawAudioURL,
                enableNoiseReduction: Self.enableNoiseReduction,
                progressHandler: { prog, status in
                    // 将预处理内部进度 0→1 映射到整体 9%→23%
                    let mapped = 0.09 + prog * 0.14
                    progressHandler(mapped, status)
                }
            )
        } catch let error as PreprocessError {
            throw SpeechToTextError.preprocessingFailed(error.localizedDescription)
        } catch {
            throw SpeechToTextError.preprocessingFailed(error.localizedDescription)
        }
        progressHandler(0.24, "预处理完成")

        // 阶段 3：VAD 静音检测 — 剪掉头尾静音（24%→28%）
        progressHandler(0.25, "正在检测语音段落...")
        try Task.checkCancellation()
        let speechSegments: [SpeechSegment]
        do {
            speechSegments = try preprocessor.detectSpeechSegments(url: cleanURL)
        } catch {
            throw SpeechToTextError.preprocessingFailed("语音段落检测失败：\(error.localizedDescription)")
        }

        guard !speechSegments.isEmpty else {
            throw SpeechToTextError.noSpeechDetected
        }

        let totalDuration = {
            let asset = AVURLAsset(url: cleanURL)
            return CMTimeGetSeconds(asset.duration)
        }()
        let firstStart = speechSegments.first!.startTime
        let lastEnd = speechSegments.last!.endTime

        let finalAudioURL: URL
        var timelineOffset: TimeInterval = 0
        if speechSegments.count == 1, speechSegments[0].startTime <= 0.05 {
            finalAudioURL = cleanURL
        } else if firstStart > 0.1 || lastEnd < totalDuration - 0.1 {
            progressHandler(0.26, "正在裁剪静音...")
            try Task.checkCancellation()
            do {
                finalAudioURL = try await preprocessor.trimSilence(
                    url: cleanURL,
                    startTime: firstStart,
                    endTime: lastEnd
                )
                timelineOffset = firstStart
            } catch {
                // 裁剪失败不终止，回退到未裁剪的音频
                finalAudioURL = cleanURL
            }
        } else {
            finalAudioURL = cleanURL
        }
        progressHandler(0.28, "语音段落分析完成")

        // 阶段 4：语音识别（28%→95%，带芯片自适应超时熔断）
        progressHandler(0.29, "正在识别语音...")

        let locale: Locale
        if let lang = language, !lang.isEmpty {
            locale = Locale(identifier: lang)
        } else {
            locale = Locale(identifier: "zh-CN")
        }

        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable else {
            throw SpeechToTextError.recognizerUnavailable
        }
        recognizer.defaultTaskHint = Self.recognitionTaskHint
        guard recognizer.supportsOnDeviceRecognition else { throw SpeechToTextError.recognizerUnavailable }

        let request = SFSpeechURLRecognitionRequest(url: finalAudioURL)
        request.requiresOnDeviceRecognition = Self.requiresOnDeviceRecognition
        request.shouldReportPartialResults = true

        if !hotwords.isEmpty {
            request.contextualStrings = hotwords
        }
        if language == nil {
            request.taskHint = .unspecified
        }

        let recognizerTotalDuration = CMTimeGetSeconds(AVURLAsset(url: finalAudioURL).duration)

        let session = RecognitionSession()
        taskRef.set(session)
        defer { taskRef.clear(session) }
        let timeoutTask = Task {
            do { try await Task.sleep(nanoseconds: Self.recognitionTimeout) } catch { return }
            session.cancel()
        }
        defer { timeoutTask.cancel() }
        let offset = timelineOffset
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<TranscriptionResult, Error>) in
            var lastProgress: Double = 0
            session.install(continuation)
            if Task.isCancelled { session.cancel(); return }
            let speechTask = recognizer.recognitionTask(with: request) { result, error in
                guard !session.isFinished else { return }

                if let error = error {
                    let nsErr = error as NSError
                    if nsErr.domain == "kAFAssistantErrorDomain" && [1, 216].contains(nsErr.code) {
                        session.finish(.failure(SpeechToTextError.cancelled))
                    } else {
                        session.finish(.failure(error))
                    }
                    return
                }

                guard let result = result else { return }

                let recognizedDuration = result.bestTranscription.segments.last?.timestamp ?? 0
                let rawProgress = recognizerTotalDuration > 0
                    ? min(recognizedDuration / recognizerTotalDuration, 0.95)
                    : 0.5
                let progress = 0.29 + rawProgress * 0.64
                if progress > lastProgress + 0.03 {
                    lastProgress = progress
                    progressHandler(progress, "正在识别语音...")
                }

                guard result.isFinal else { return }

                progressHandler(0.95, "正在整理结果...")

                let fullText = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !fullText.isEmpty else {
                    session.finish(.failure(SpeechToTextError.noSpeechDetected))
                    return
                }

                var entries: [SubtitleEntry]
                let segments = result.bestTranscription.segments
                if segments.isEmpty {
                    entries = [SubtitleEntry(
                        index: 1, startTime: 0,
                        endTime: recognizerTotalDuration, text: fullText
                    )]
                } else {
                    entries = self.mergeSegments(segments, totalDuration: recognizerTotalDuration)
                }

                if offset > 0 {
                    entries = entries.map { e in
                        var adjusted = e
                        adjusted.startTime = e.startTime + offset
                        adjusted.endTime = e.endTime + offset
                        return adjusted
                    }
                }

                var detectedLang: String?
                if #available(macOS 10.15, *) {
                    let langRecognizer = NLLanguageRecognizer()
                    langRecognizer.processString(result.bestTranscription.formattedString)
                    detectedLang = langRecognizer.dominantLanguage?.rawValue
                }

                let transcription = TranscriptionResult(
                    entries: entries,
                    fullText: fullText,
                    detectedLanguage: detectedLang,
                    confidence: 0.8
                )

                progressHandler(1.0, "识别完成")
                session.finish(.success(transcription))
            }

            session.attach(speechTask)
            }
        }, onCancel: { session.cancel() })
    }

    // MARK: 双语翻译（macOS 15.0+，使用 Translation 框架本地离线翻译）

    /// 批量翻译字幕条目，将 translatedText 填充到每个条目中
    /// - Parameter session: 由 SwiftUI `.translationTask()` 创建的 TranslationSession
    @available(macOS 15.0, *)
    func translateSubtitles(
        _ entries: [SubtitleEntry],
        using session: TranslationSession
    ) async throws -> [SubtitleEntry] {
        var translated = entries

        let indexedTexts = entries.enumerated()
            .filter { !$0.element.text.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !indexedTexts.isEmpty else { return translated }

        let requests: [TranslationSession.Request] = indexedTexts.map {
            TranslationSession.Request(sourceText: $0.element.text.trimmingCharacters(in: .whitespaces))
        }

        let responses = try await session.translations(from: requests)

        for (respIdx, (entryIdx, _)) in indexedTexts.enumerated() {
            guard respIdx < responses.count else { continue }
            translated[entryIdx].translatedText = responses[respIdx].targetText
        }

        return translated
    }

    /// 将翻译后的条目拼接为完整的译文全文
    func translatedFullText(from entries: [SubtitleEntry]) -> String {
        entries.compactMap { $0.translatedText }.joined()
    }

    // MARK: 字幕导出

    func exportSRT(_ entries: [SubtitleEntry], outputURL: URL) throws {
        var lines: [String] = []
        for entry in entries {
            lines.append("\(entry.index)")
            lines.append("\(formatSRTTime(entry.startTime)) --> \(formatSRTTime(entry.endTime))")
            if let trans = entry.translatedText, !trans.isEmpty {
                lines.append("\(entry.text)\n\(trans)")
            } else {
                lines.append(entry.text)
            }
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    func exportVTT(_ entries: [SubtitleEntry], outputURL: URL) throws {
        var lines: [String] = ["WEBVTT", ""]
        for entry in entries {
            lines.append("\(formatVTTTime(entry.startTime)) --> \(formatVTTTime(entry.endTime))")
            if let trans = entry.translatedText, !trans.isEmpty {
                lines.append("\(entry.text)\n\(trans)")
            } else {
                lines.append(entry.text)
            }
            lines.append("")
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    func exportTXT(_ entries: [SubtitleEntry], outputURL: URL) throws {
        var lines: [String] = []
        for entry in entries {
            let ts = formatSimpleTime(entry.startTime)
            if let trans = entry.translatedText, !trans.isEmpty {
                lines.append("[\(ts)] \(entry.text)")
                lines.append("[\(ts)] \(trans)")
            } else {
                lines.append("[\(ts)] \(entry.text)")
            }
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    // MARK: 纯文本导出（无时间戳、无分段、无换行，一整段连贯文本）

    func exportPlainText(_ fullText: String, outputURL: URL) throws {
        let cleaned = fullText
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try cleaned.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// 双语纯文本导出：原文 + 译文，以双换行分隔
    func exportPlainTextBilingual(fullText: String, translatedFullText: String, outputURL: URL) throws {
        let cleaned = fullText
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let translatedCleaned = translatedFullText
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = "\(cleaned)\n\n\(translatedCleaned)"
        try combined.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    // MARK: 时间格式化

    private func formatSRTTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func formatVTTTime(_ t: TimeInterval) -> String {
        let h = Int(t) / 3600
        let m = (Int(t) % 3600) / 60
        let s = Int(t) % 60
        let ms = Int((t - Double(Int(t))) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    private func formatSimpleTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}
