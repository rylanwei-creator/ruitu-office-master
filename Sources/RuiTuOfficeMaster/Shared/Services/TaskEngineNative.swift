import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreGraphics

struct ToolExecutionFailure: Error, LocalizedError, Sendable {
    let results: [RToolAIResult]
    let cancelled: Bool
    let reason: String
    var errorDescription: String? { reason }
}
extension TaskEngine {
    static func executeNative(_ plan: RitoPreparedTool, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [RToolAIResult] {
        if plan.call.operation == .collage { return try await executeCollage(plan, progress: progress) }
        if plan.call.operation == .file_rename {
            guard let preview = plan.renamePreview else { throw RitoToolError.invalidPlan }
            let result = FileRenameService().execute(previewItems: preview, shouldStop: { Task.isCancelled }) { value in Task { await progress(value) } }
            switch result {
            case .success(let moves):
                return moves.map { .init(sourceName: $0.renamed.lastPathComponent, detail: "已改名：" + $0.original.lastPathComponent + " → " + $0.renamed.lastPathComponent,
                    fileReference: RitoResultFile.safeExtensions.contains($0.renamed.pathExtension.lowercased()) ? .capture($0.renamed) : nil, renameRecovery: $0) }
            case .failure(let errors): throw ToolExecutionError.message(errors.joined(separator: "\n"))
            }
        }
        let values = plan.parameters
        var rootIdentity: OrganizerDirectoryIdentity?
        if let root = plan.destination {
            guard let identity = plan.destinationIdentity,
                  try OrganizerDirectoryIdentity.read(root.deletingLastPathComponent()) == identity else { throw RitoToolError.changed }
            try FileOrganizerService.noLinks(root)
            guard !FileManager.default.fileExists(atPath: root.path) else { throw RitoToolError.destinationOccupied }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            rootIdentity = try OrganizerDirectoryIdentity.read(root)
        }
        var results: [RToolAIResult] = []
        for (index, url) in plan.urls.enumerated() {
            if plan.call.operation == .pdf_image_watermark && index > 0 { continue }
            do {
                try Task.checkCancellation()
                try FileOrganizerService.noLinks(url)
                guard try OrganizerStamp.read(url) == plan.stamps[index] else { throw RitoToolError.changed }
                if plan.call.operation == .pdf_ocr {
                    let text = try await OCRService().recognizePDF(url: url, languages:[values["language"] ?? "auto"], preprocess:values["preprocess"] != "false") { _,_ in }
                    results.append(.init(sourceName: url.lastPathComponent,detail:text))
                    await progress(Double(index + 1) / Double(plan.urls.count)); continue
                }
                guard let root = plan.destination, let rootIdentity,
                      try OrganizerDirectoryIdentity.read(root) == rootIdentity else { throw RitoToolError.changed }
                try FileOrganizerService.noLinks(root)
                let ext: String
                switch plan.call.operation {
                case .image_convert: ext = values["format"] ?? "jpg"
                case .image_compress, .image_resize:
                    ext = try ImageCompressionService().outputType(for: outputFormat(values["format"] ?? "original"), originalURL: url).preferredFilenameExtension ?? "jpg"
                case .cutout,.watermark_remove: ext = "png"
                case .id_photo: ext = values["format"] ?? "jpg"
                case .pdf_merge,.pdf_split,.pdf_encrypt,.pdf_watermark,.pdf_image_watermark,.word_to_pdf,.id_photo_print: ext = "pdf"
                case .pdf_to_word: ext = "docx"
                case .video_compress: ext = values["format"] ?? "mp4"
                case .video_to_gif,.gif_compress: ext = "gif"
                case .speech_to_text: ext = values["format"] ?? "txt"
                default: throw RitoToolError.invalidPlan
                }
                let stage = root.appendingPathComponent(".stage-" + UUID().uuidString + "." + ext)
                defer { try? FileManager.default.removeItem(at: stage) }
                var detail = "实际本机处理完成，原文件保留。"
                switch plan.call.operation {
                case .image_convert:
                    guard let format = conversion(ext) else { throw RitoToolError.invalidPlan }
                    try await ImageCompressionWorker.shared.convert(url: url, format: format, outputURL: stage)
                case .image_compress:
                    let goal: ImageSizeGoal
                    if let maximum = Double(values["maximumKB"] ?? "") {
                        let minimum = Double(values["minimumKB"] ?? "") ?? 1
                        goal = .range(minimum:Int64(minimum * 1024),maximum:Int64(maximum * 1024))
                    } else { goal = .reduction(number(values,"reduction")) }
                    let dimensions = imageDimensions(values)
                    let temporary = root.appendingPathComponent(".target-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at:temporary) }
                    let prepared = try await ImageCompressionWorker.shared.prepareTarget(url:url,options:.init(goal:goal,
                        format:outputFormat(values["format"] ?? "original"),qualityFloor:number(values,"qualityFloor"),
                        maxDimension:dimensions.maximum,targetSize:dimensions.exact,fitWithin:dimensions.fit,allowResize:values["allowResize"] != "false"),directory:temporary)
                    try await ImageCompressionWorker.shared.exportTarget(url:url,prepared:prepared,outputURL:stage)
                    detail = prepared.detail
                case .image_resize:
                    let dimensions = imageDimensions(values)
                    try await ImageCompressionWorker.shared.compress(url: url, quality:number(values,"quality"),maxDimension:dimensions.maximum,
                        outputFormat:outputFormat(values["format"] ?? "original"),outputURL:stage,targetSize:dimensions.exact,
                        fitWithin:dimensions.fit)
                case .cutout:
                    let asset = try ImageCleanupService.prepare(url)
                    let result = try NativeImageProcessingProvider().cutout(asset.image)
                    try ImageCodec.encode(result.image,type:.png,quality:1).write(to:stage,options:.withoutOverwriting)
                    detail = "保留 \(result.subjects) 个前景主体；透明PNG；请检查边缘。"
                case .watermark_remove:
                    let asset = try ImageCleanupService.prepare(url), region = try cleanupRegion(values)
                    guard plan.call.regionConfirmed == true else { throw RitoToolError.invalidPlan }
                    let image = try values["method"] == "sample"
                        ? ImageCleanupService.sample(asset.image, region:region,center:CGPoint(x:number(values,"sampleX"),y:number(values,"sampleY")),feather:number(values,"feather"))
                        : ImageCleanupService.surrounding(asset.image,region:region)
                    try ImageCodec.encode(image,type:.png,quality:1).write(to:stage,options:.withoutOverwriting)
                    detail = "已修补用户确认的区域；不保证恢复被遮挡细节，请对比原图。"
                case .id_photo,.id_photo_print:
                    let asset = try await IDPhotoWorker.shared.prepare(url:url)
                    let result = try await IDPhotoWorker.shared.render(asset:asset,settings:photoSettings(values))
                    let data = plan.call.operation == .id_photo_print
                        ? try IDPhotoService.printPDF(result:result,paper:values["paper"] == "a4" ? .a4 : .sixInch,cropMarks:values["cropMarks"] != "false")
                        : result.data
                    try data.write(to:stage,options:.withoutOverwriting)
                    detail = plan.call.operation == .id_photo_print ? "实际尺寸打印PDF；请选择100%打印并关闭适应纸张。" : "证件照已生成；请核对尺寸、背景与构图。"
                case .pdf_split:
                    let count = PDFService().pageCount(of:url)
                    let ranges = try PageRangeParser.parse(values["ranges"] ?? "",pageCount:count)
                    let stagingFolder = root.appendingPathComponent(".split-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at:stagingFolder) }
                    let files = try PDFService().split(url:url,ranges:ranges,outputDir:stagingFolder)
                    for (part, file) in files.enumerated() {
                        try Task.checkCancellation()
                        guard try OrganizerDirectoryIdentity.read(root) == rootIdentity else { throw RitoToolError.changed }
                        try FileOrganizerService.noLinks(root)
                        guard try OrganizerStamp.read(url) == plan.stamps[index] else { throw RitoToolError.changed }
                        let output = root.appendingPathComponent("\(index + 1)_\(part + 1)_" + file.lastPathComponent)
                        try FileManager.default.moveItem(at:file,to:output)
                        results.append(.init(sourceName:output.lastPathComponent,detail:"PDF拆分真实结果，原PDF保留。",fileReference:.capture(output)))
                    }
                    await progress(Double(index + 1)/Double(plan.urls.count)); continue
                case .pdf_encrypt:
                    guard let password = plan.localPassword else { throw RitoToolError.invalidPlan }
                    try PDFService().encrypt(url:url,config:.init(userPassword:password,ownerPassword:plan.localOptions.ownerPassword,
                        allowPrinting:values["allowPrinting"] != "false",allowCopying:values["allowCopying"] == "true"),outputURL:stage)
                    detail = "已生成加密PDF；密码未记录到聊天或执行日志。"
                case .pdf_watermark:
                    try PDFService().addWatermark(url:url,type:.text(values["text"] ?? "",fontSize:number(values,"fontSize"),
                        color:CGColor(gray:0.4,alpha:1),rotation:number(values,"rotation"),opacity:number(values,"opacity")),outputURL:stage)
                case .pdf_image_watermark:
                    guard plan.urls.count == 2 else { throw RitoToolError.invalidPlan }
                    try PDFService().addWatermark(url:url,type:.image(plan.urls[1],scale:number(values,"scale"),opacity:number(values,"opacity")),outputURL:stage)
                case .word_to_pdf: try DocumentConversionService().wordToPDF(url:url,outputURL:stage)
                case .pdf_to_word:
                    try DocumentConversionService().pdfToWord(url:url,outputURL:stage)
                    detail = "已提取PDF文字到Word；不保留原版式，扫描页请用PDF OCR。"
                case .video_compress:
                    let quality: VideoQuality = values["quality"] == "high" ? .high : values["quality"] == "low" ? .low : .medium
                    let resolution: VideoResolution
                    switch values["resolution"] { case "original": resolution = .original; case "uhd4K": resolution = .uhd4K; case "fullHD": resolution = .fullHD; case "sd": resolution = .sd; default: resolution = .hd }
                    try await VideoCompressionService().compress(url:url,quality:quality,resolution:resolution,
                        codec:values["codec"] == "hevc" ? .hevc : .h264,outputFormat:ext == "mov" ? .mov : .mp4,outputURL:stage) { value in
                            Task { await progress((Double(index) + value) / Double(plan.urls.count)) }
                        }
                case .video_to_gif:
                    _ = try GIFGenerationService().generateGIF(from:url,frameRate:Int(number(values,"frameRate")),
                        maxDimension:number(values,"maxDimension"),startTime:number(values,"start"),duration:number(values,"duration"),
                        outputURL:stage) { value,_ in Task { await progress((Double(index) + value)/Double(plan.urls.count)) } }
                case .gif_compress:
                    _ = try GIFGenerationService().compressGIF(url:url,maxDimension:number(values,"maxDimension"),
                        frameSkip:Int(number(values,"frameSkip")),outputURL:stage) { value,_ in Task { await progress((Double(index) + value)/Double(plan.urls.count)) } }
                case .speech_to_text:
                    let service = SpeechToTextService()
                    let text = try await service.transcribe(url:url,language:values["language"] == "auto" ? nil : values["language"]) { value,_ in
                        Task { await progress((Double(index) + value)/Double(plan.urls.count)) }
                    }
                    switch ext { case "srt": try service.exportSRT(text.entries,outputURL:stage); case "vtt": try service.exportVTT(text.entries,outputURL:stage); default: try service.exportPlainText(text.fullText,outputURL:stage) }
                default: throw RitoToolError.invalidPlan
                }
                try Task.checkCancellation()
                guard try OrganizerDirectoryIdentity.read(root) == rootIdentity else { throw RitoToolError.changed }
                try FileOrganizerService.noLinks(root)
                for (source, stamp) in zip(plan.urls,plan.stamps) {
                    guard try OrganizerStamp.read(source) == stamp else { throw RitoToolError.changed }
                }
                var name = url.deletingPathExtension().lastPathComponent
                while name.utf8.count > 120 { name.removeLast() }
                let output = root.appendingPathComponent("\(index + 1)_" + name + "_" + ToolRegistry.lookup(plan.call.operation).name + "." + ext)
                detail += " · " + FileUtils.formatSize(FileUtils.fileSize(of:url)) + " → " + FileUtils.formatSize(FileUtils.fileSize(of:stage))
                try FileManager.default.moveItem(at:stage,to:output)
                results.append(.init(sourceName:output.lastPathComponent,detail:detail,
                    previewData:ToolRegistry.imageExtensions.contains(ext) ? RitoImagePreview.data(from:output) : nil,fileReference:.capture(output)))
                await progress(Double(index + 1)/Double(plan.urls.count))
            } catch is CancellationError {
                throw ToolExecutionFailure(results:results,cancelled:true,reason:"任务已停止，已生成文件保留。")
            } catch {
                results.append(.init(sourceName:url.lastPathComponent,detail:"未完成：" + error.localizedDescription,failed:true))
            }
        }
        await progress(1)
        if results.contains(where: { $0.failed == true }) {
            throw ToolExecutionFailure(results:results,cancelled:false,reason:"部分文件未完成；成功结果已保留，重试会生成新的输出位置。")
        }
        return results
    }

    private static func executeCollage(_ plan: RitoPreparedTool, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [RToolAIResult] {
        guard let root = plan.destination,
              let parentIdentity = plan.destinationIdentity,
              try OrganizerDirectoryIdentity.read(root.deletingLastPathComponent()) == parentIdentity else { throw RitoToolError.changed }
        try FileOrganizerService.noLinks(root)
        guard !FileManager.default.fileExists(atPath: root.path) else { throw RitoToolError.destinationOccupied }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let rootIdentity = try OrganizerDirectoryIdentity.read(root)
        let settings = try collageSettings(plan.parameters)
        let photos = try collagePhotos(plan.urls, ids: plan.call.attachmentIDs, options: plan.localOptions)
        let geometry = try CollageService.geometry(sizes: photos.map(\.size), settings: settings)
        let ext = settings.format.fileExtension
        let stage = root.appendingPathComponent(".stage-" + UUID().uuidString + "." + ext)
        let output = root.appendingPathComponent("拼图." + ext)
        defer { try? FileManager.default.removeItem(at: stage) }
        try CollageService.export(photos: photos, settings: settings, to: stage) { value in
            Task { await progress(max(0, min(0.95, value * 0.95))) }
        }
        try Task.checkCancellation()
        guard try OrganizerDirectoryIdentity.read(root) == rootIdentity,
              try OrganizerDirectoryIdentity.read(root.deletingLastPathComponent()) == parentIdentity,
              !FileManager.default.fileExists(atPath: output.path) else { throw RitoToolError.changed }
        for (url, stamp) in zip(plan.urls, plan.stamps) {
            try FileOrganizerService.noLinks(url)
            guard try OrganizerStamp.read(url) == stamp else { throw RitoToolError.changed }
        }
        try FileManager.default.moveItem(at: stage, to: output)
        let detail = "已将 \(photos.count) 张图片按附件顺序拼接；\(Int(geometry.size.width)) × \(Int(geometry.size.height)) px，\(settings.format.rawValue)。原图保留。"
        await progress(1)
        return [.init(sourceName: output.lastPathComponent, detail: detail,
                      previewData: RitoImagePreview.data(from: output), fileReference: .capture(output))]
    }
}
