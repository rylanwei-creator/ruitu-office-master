import Foundation
import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Orchestrates approved tools only. Algorithms live in the same services as ordinary tool pages.
enum TaskEngine {
    static let legacy: Set<RitoToolCall.Operation> = [.ocr,.pdf_merge,.organize_copy,.organize_move]
    static func validateChain(_ call: RitoToolCall) throws {
        let stages = call.following ?? []
        guard stages.count <= 3 else { throw RitoToolError.invalidPlan }
        let restricted: Set<RitoToolCall.Operation> = [.file_rename,.organize_move,.organize_copy,.pdf_encrypt,.watermark_remove,.pdf_image_watermark]
        if !stages.isEmpty, restricted.contains(call.operation) { throw ToolExecutionError.message("改名、整理、加密与区域修补暂作为独立确认任务执行。") }
        var previous = call.operation
        var previousParameters = call.parameters ?? [:]
        var count = call.attachmentIDs.count
        if call.operation == .pdf_merge { count = 1 }
        if call.operation == .pdf_split { count = (call.parameters?["ranges"] ?? "").replacingOccurrences(of:"，",with:",").components(separatedBy:",").count }
        if call.operation == .collage { guard (2...8).contains(count) else { throw RitoToolError.invalidPlan }; count = 1 }
        for stage in stages {
            guard !restricted.contains(stage.operation) else { throw RitoToolError.invalidPlan }
            let previousTool = ToolRegistry.lookup(previous), nextTool = ToolRegistry.lookup(stage.operation)
            _ = try nextTool.values(stage.parameters ?? [:], allowMissing: true)
            let ext: String
            switch previousTool.output {
            case "图片", "jpg/png": ext = "png"
            case "png/jpg": ext = previousParameters["format"] == CollageFormat.jpeg.rawValue ? "jpg" : "png"
            case "mp4/mov": ext = "mp4"
            case "txt/srt/vtt": ext = "txt"
            default: ext = previousTool.output
            }
            guard nextTool.accepts(.init(id: UUID(), name: "generated." + ext, byteCount: 0)),
                  previousTool.output != "文字" else { throw ToolExecutionError.message("后续工具的输入类型与上一步输出不匹配，未执行。") }
            guard count <= 8, stage.operation != .pdf_merge || count >= 2,
                  ![.id_photo,.id_photo_print,.pdf_split].contains(stage.operation) || count == 1 else {
                throw ToolExecutionError.message("后续工具所需的文件数量与上一步输出不匹配，未执行。")
            }
            if stage.operation == .pdf_merge { count = 1 }
            if stage.operation == .pdf_split { count = (stage.parameters?["ranges"] ?? "").replacingOccurrences(of:"，",with:",").components(separatedBy:",").count }
            if stage.operation == .collage { guard (2...8).contains(count) else { throw RitoToolError.invalidPlan }; count = 1 }
            previous = stage.operation
            previousParameters = stage.parameters ?? [:]
        }
    }

    static func prepare(_ call: RitoToolCall, files: [UUID: URL], destination: URL?, password: String? = nil, localOptions: RitoLocalToolOptions = .init()) async throws -> RitoPreparedTool {
        try validateChain(call)
        let selected = try call.attachmentIDs.map { id -> RToolAIAttachment in
            guard let url = files[id] else { throw RitoToolError.missingFiles }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let directory = (try url.resourceValues(forKeys:[.isDirectoryKey])).isDirectory == true
            return .init(id:id,name:url.lastPathComponent,byteCount:0,isDirectory:directory)
        }
        try ToolRegistry.validate(call,attachments:selected)
        let values = try ToolRegistry.lookup(call.operation).values(call.parameters ?? [:])
        if legacy.contains(call.operation), !(call.operation == .pdf_merge && !(call.following ?? []).isEmpty) {
            return try RitoToolExecutor.prepare(call, files: files, destination: destination, localOptions: localOptions)
        }
        let urls = try call.attachmentIDs.map { id -> URL in
            guard let url = files[id] else { throw RitoToolError.missingFiles }
            try FileOrganizerService.noLinks(url)
            return url
        }
        let accesses = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { accesses.forEach { $0.stopAccessingSecurityScopedResource() } }
        let attachments = urls.enumerated().map { index, url in
            RToolAIAttachment(id: call.attachmentIDs[index], name: url.lastPathComponent, byteCount: FileUtils.fileSize(of: url), isDirectory: false)
        }
        try ToolRegistry.validate(call, attachments: attachments)
        let stamps = try urls.map { try OrganizerStamp.read($0) }
        var summary = ["工具：" + ToolRegistry.lookup(call.operation).name,
                       "输入：" + urls.map(\.lastPathComponent).joined(separator: "、"),
                       "风险：" + ToolRegistry.lookup(call.operation).risk.rawValue,
                       "覆盖原文件：否"]
        summary += ToolRegistry.lookup(call.operation).parameterSummary(values)
        var rename: [RenamePreviewItem]?, preview: Data?
        if call.operation == .file_rename {
            let mode = renameMode(values["mode"] ?? "prefix")
            guard mode == .replace || !(values["text"] ?? "").isEmpty else { throw ToolExecutionError.message("请输入前后缀或序号名称。") }
            guard mode != .replace || !(values["find"] ?? "").isEmpty else { throw ToolExecutionError.message("请设置查找文字。") }
            let items = FileRenameService().generatePreview(files: urls, mode: mode, prefix: values["text"] ?? "", suffix: values["text"] ?? "",
                findText: values["find"] ?? "", replaceText: values["text"] ?? "", numberText: values["text"] ?? "",
                startNumber: Int(values["start"] ?? "1") ?? 1, numberDigits: Int(values["digits"] ?? "3") ?? 3)
            guard !items.isEmpty, items.contains(where: \.isValid), items.allSatisfy({ $0.conflictReason == nil }) else {
                throw ToolExecutionError.message(items.compactMap(\.conflictReason).first ?? "这些文件名没有变化。")
            }
            rename = items
            summary += items.map { $0.originalName + " → " + $0.newName }
            summary.append("原文件位置将改变；处理失败尝试回滚。执行完成后可撤销改名。")
        } else if call.operation == .pdf_ocr {
            for url in urls { try PDFService().validate(url: url) }
            summary.append("仅在本机识别，不向聊天 API 上传结果。")
        } else {
            guard let destination else { throw RitoToolError.missingFiles }
            try FileOrganizerService.noLinks(destination)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw RitoToolError.destinationOccupied }
            summary.append("输出格式：" + ToolRegistry.lookup(call.operation).output)
            summary.append("输出位置：" + destination.path)
        }
        if ToolRegistry.lookup(call.operation).input == .image {
            for url in urls { try ImageCodec.validateStaticImage(at: url) }
        }
        if call.operation == .collage {
            guard let destination else { throw RitoToolError.missingFiles }
            let settings = try collageSettings(values)
            let photos = try collagePhotos(urls, ids: call.attachmentIDs, options: localOptions)
            let geometry = try CollageService.geometry(sizes: photos.map(\.size), settings: settings)
            let previewImage = try CollageService.render(photos: photos, settings: settings, previewMaximum: 960)
            let encoded = try ImageCodec.encode(previewImage, type: .png, quality: 1)
            summary += ["图片数量：\(photos.count) 张（按附件顺序）",
                        "布局：\(settings.mode.rawValue) · \(settings.mode == .grid ? settings.template.rawValue + " · " + settings.ratio.rawValue : "保持原图比例")",
                        "背景/滤镜：\(settings.background.rawValue) / \(settings.filter.rawValue)",
                        "预计输出：\(Int(geometry.size.width)) × \(Int(geometry.size.height)) px，\(settings.format.rawValue)",
                        "标题：\(settings.caption.isEmpty ? "无" : settings.caption)",
                        "预览为缩略图；确认后由本机拼图服务生成完整文件。原图保留。"]
            preview = encoded
        }
        if call.operation == .pdf_image_watermark {
            try PDFService().validate(url:urls[0]); try ImageCodec.validateStaticImage(at:urls[1])
            summary.append("图片水印附件：" + urls[1].lastPathComponent)
        }
        if ToolRegistry.lookup(call.operation).input == .pdf {
            for url in urls { try PDFService().validate(url: url) }
        }
        if call.operation == .image_convert {
            guard let format = conversion(values["format"] ?? "jpg"), ConversionFormat.available.contains(format) else { throw CompressionError.unsupportedOutput(values["format"] ?? "") }
        }
        if call.operation == .image_compress || call.operation == .image_resize {
            for url in urls { _ = try ImageCompressionService().outputType(for:outputFormat(values["format"] ?? "original"),originalURL:url) }
        }
        if call.operation == .watermark_remove {
            guard call.regionConfirmed == true else { throw ToolExecutionError.message("请点击设置参数，在原图上框选并确认水印区域。") }
            let asset = try ImageCleanupService.prepare(urls[0]), region = try cleanupRegion(values)
            _ = try region.pixels(in: asset.size)
            if values["method"] == "sample" { _ = try region.sampleRegion(center: CGPoint(x: number(values,"sampleX"), y: number(values,"sampleY"))) }
            summary.append("修补不能保证恢复被遮挡细节，请检查处理预览后保存。")
        }
        if call.operation == .pdf_split {
            let count = PDFService().pageCount(of: urls[0])
            _ = try PageRangeParser.parse(values["ranges"] ?? "", pageCount: count)
            summary.append("原PDF总页数：\(count)")
        }
        if call.operation == .pdf_encrypt {
            guard let password, !password.isEmpty, password.count <= 128 else { throw ToolExecutionError.message("请在本机设置PDF打开密码。") }
            guard localOptions.ownerPassword.count <= 128, localOptions.ownerPassword.isEmpty || localOptions.ownerPassword != password else {
                throw ToolExecutionError.message("权限密码须与打开密码不同，最多128字符。")
            }
            summary.append("密码已在本机设置，不显示、不保存到聊天记录、不上传。")
        }
        if call.operation == .id_photo || call.operation == .id_photo_print {
            let asset = try await IDPhotoWorker.shared.prepare(url: urls[0])
            let settings = photoSettings(values)
            let result = try await IDPhotoWorker.shared.render(asset: asset, settings: settings)
            preview = call.operation == .id_photo_print
                ? try IDPhotoService.printPreview(result: result, paper: values["paper"] == "a4" ? .a4 : .sixInch, cropMarks: values["cropMarks"] != "false").data
                : result.data
            summary.append("请检查人像边缘与裁切构图；尺寸预设不代表接收单位的要求。")
        }
        for (index, stage) in (call.following ?? []).enumerated() {
            let tool = ToolRegistry.lookup(stage.operation)
            let parameters = try tool.values(stage.parameters ?? [:])
            let rows = tool.parameterSummary(parameters)
            summary.append("第\(index + 2)步：" + tool.name + "；输入为上一步生成文件" + (rows.isEmpty ? "" : "；" + rows.joined(separator: "，")))
        }
        return .init(call: call, urls: urls, stamps: stamps, destination: destination,
            destinationIdentity: try destination.map { try OrganizerDirectoryIdentity.read($0.deletingLastPathComponent()) },
            organizer: nil, summary: summary, parameters: values, renamePreview: rename, localPassword: call.operation == .pdf_encrypt ? password : nil, previewData: preview.flatMap { RitoImagePreview.data(from:$0) }, localOptions: localOptions)
    }

    private static func run(_ plan: RitoPreparedTool, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [RToolAIResult] {
        let stages = plan.call.following ?? []
        var firstDestination = plan.destination, firstIdentity = plan.destinationIdentity
        if plan.call.operation == .pdf_merge, !stages.isEmpty {
            guard let root = plan.destination, let identity = plan.destinationIdentity,
                  try OrganizerDirectoryIdentity.read(root.deletingLastPathComponent()) == identity,
                  !FileManager.default.fileExists(atPath:root.path) else { throw RitoToolError.changed }
            try FileOrganizerService.noLinks(root)
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
            firstDestination = root.appendingPathComponent("步骤1.pdf")
            firstIdentity = try OrganizerDirectoryIdentity.read(root)
        }
        let first = RitoPreparedTool(call: .init(operation: plan.call.operation, attachmentIDs: plan.call.attachmentIDs, parameters: plan.call.parameters, regionConfirmed: plan.call.regionConfirmed),
            urls: plan.urls, stamps: plan.stamps, destination: firstDestination, destinationIdentity: firstIdentity,
            organizer: plan.organizer, summary: plan.summary, parameters: plan.parameters, renamePreview: plan.renamePreview, localPassword: plan.localPassword, previewData: plan.previewData, localOptions: plan.localOptions)
        var results = try await RitoToolExecutor.execute(first) { value in progress(value / Double(stages.count + 1)) }
        guard !stages.isEmpty else { return results }
        guard let root = plan.destination else { throw RitoToolError.missingFiles }
        for (index, stage) in stages.enumerated() {
            do {
            try Task.checkCancellation()
            let urls = try results.compactMap { try $0.fileReference?.resolvedURL() }
            guard !urls.isEmpty else { throw ToolExecutionError.message("上一步没有可供后续工具使用的输出文件，已停止。") }
            let ids = urls.map { _ in UUID() }
            let call = RitoToolCall(operation: stage.operation, attachmentIDs: ids, parameters: stage.parameters)
            let destination = root.appendingPathComponent("步骤\(index + 2)" + (stage.operation == .pdf_merge ? ".pdf" : ""))
            let next = try await prepare(call, files: Dictionary(uniqueKeysWithValues: zip(ids,urls)), destination: destination)
            results = try await RitoToolExecutor.execute(next) { value in progress((Double(index + 1) + value) / Double(stages.count + 1)) }
            } catch {
                let partial = error as? ToolExecutionFailure
                throw ToolExecutionFailure(results:results + (partial?.results ?? []),cancelled:Task.isCancelled || partial?.cancelled == true,
                    reason:"第\(index + 2)步未完成：" + error.localizedDescription + "；先前输出已保留。")
            }
        }
        return results
    }
    static func execute(_ plan: RitoPreparedTool, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [RToolAIResult] {
        guard await ToolExecutionGate.shared.enter() else { throw ToolExecutionError.message("上一个任务仍在停止或恢复，请稍后再试。") }
        var record = NativeToolTaskRecord(tool:plan.call.operation.rawValue, output:plan.destination, state:"running", results:[])
        guard NativeToolTaskJournal.save(record) else {
            await ToolExecutionGate.shared.leave()
            throw ToolExecutionError.message("无法保存执行记录，未开始处理；请检查应用存储位置权限。")
        }
        do {
            let results = try await run(plan,progress:progress)
            record.state = "completed"; record.results = results
            guard NativeToolTaskJournal.save(record) else { throw ToolExecutionFailure(results:results,cancelled:false,reason:"文件处理已完成，但执行记录保存失败；请保留并检查输出目录。") }
            await ToolExecutionGate.shared.leave(); return results
        } catch {
            record.state = Task.isCancelled ? "cancelled" : "failed"
            if let partial = error as? ToolExecutionFailure { record.results = partial.results }
            NativeToolTaskJournal.save(record)
            await ToolExecutionGate.shared.leave(); throw error
        }
    }
    static func renameMode(_ value: String) -> RenameMode {
        switch value { case "suffix": .suffix; case "replace": .replace; case "numbering": .numbering; default: .prefix }
    }
    static func undoRename(_ moves: [RenameMove]) async -> RenameResult {
        guard await ToolExecutionGate.shared.enter() else { return .failure(errors:["上一个任务仍在停止或恢复，请稍后再试。"]) }
        let result: RenameResult
        do {
            try Task.checkCancellation()
            for move in moves { try FileOrganizerService.noLinks(move.renamed) }
            result = FileRenameService().undo(moves)
        } catch { result = .failure(errors:[error.localizedDescription]) }
        await ToolExecutionGate.shared.leave()
        return result
    }
    static func conversion(_ value: String) -> ConversionFormat? { ConversionFormat.allCases.first { $0.fileExtension == value } }
    static func outputFormat(_ value: String) -> OutputFormat {
        switch value { case "jpg": .jpg; case "png": .png; case "heic": .heic; case "webp": .webp; default: .keepOriginal }
    }
    static func number(_ values: [String:String], _ key: String) -> Double { Double(values[key] ?? "") ?? 0 }
    static func imageDimensions(_ values: [String:String]) -> (maximum: CGFloat?, exact: CGSize?, fit: CGSize?) {
        if values["sizeMode"] == "longEdge" { return (CGFloat(number(values,"maxDimension")),nil,nil) }
        let width = number(values,"width"), height = number(values,"height")
        guard width > 0, height > 0 else { return (nil,nil,nil) }
        let size = CGSize(width:width,height:height)
        return values["sizeMode"] == "exact" ? (nil,size,nil) : (nil,nil,size)
    }
    static func cleanupRegion(_ values: [String:String]) throws -> CleanupRegion {
        let region = CleanupRegion(rect: CGRect(x: number(values,"x"), y: number(values,"y"), width: number(values,"width"), height: number(values,"height")))
        _ = try region.pixels(in: CGSize(width: 4096,height:4096)); return region
    }
    static func photoSettings(_ values: [String:String]) -> IDPhotoSettings {
        var result = IDPhotoSettings()
        result.background = values["background"] == "blue" ? .blue : values["background"] == "red" ? .red : values["background"] == "white" ? .white : values["background"] == "custom" ? .custom : .original
        result.preset = values["preset"] == "two" ? .two : values["preset"] == "smallTwo" ? .smallTwo : values["preset"] == "custom" ? .custom : .one
        result.widthMM = Double(values["widthMM"] ?? "") ?? 25
        result.heightMM = Double(values["heightMM"] ?? "") ?? 35
        result.dpi = Int(values["dpi"] ?? "") ?? 300
        result.red = Double(values["red"] ?? "") ?? 1
        result.green = Double(values["green"] ?? "") ?? 1
        result.blue = Double(values["blue"] ?? "") ?? 1
        result.format = values["format"] == "png" ? .png : .jpeg
        result.crop = .init(zoom: Double(values["zoom"] ?? "1") ?? 1, x: number(values,"cropX"), y: number(values,"cropY"))
        if result.format == .jpeg, let maximum = Int(values["maximumKB"] ?? "") { result.limitSize = true; result.maximumKB = maximum }
        return result
    }
    static func collagePhotos(_ urls: [URL], ids: [UUID], options: RitoLocalToolOptions) throws -> [CollagePhoto] {
        try zip(ids, urls).map { id, url in
            var photo = try CollageService.prepare(url)
            if let crop = options.collageCrops[id] {
                photo.zoom = crop.zoom; photo.panX = crop.x; photo.panY = crop.y
            }
            return photo
        }
    }
    static func collageSettings(_ values: [String:String]) throws -> CollageSettings {
        guard let mode = CollageMode(rawValue: values["mode"] ?? CollageMode.grid.rawValue),
              let ratio = CollageRatio(rawValue: values["ratio"] ?? CollageRatio.portrait.rawValue),
              let template = CollageTemplate(rawValue: values["template"] ?? CollageTemplate.grid.rawValue),
              let background = CollageBackground(rawValue: values["background"] ?? CollageBackground.white.rawValue),
              let filter = CollageFilter(rawValue: values["filter"] ?? CollageFilter.original.rawValue),
              let format = CollageFormat(rawValue: values["format"] ?? CollageFormat.png.rawValue) else { throw RitoToolError.invalidPlan }
        let caption = values["caption"] ?? ""
        guard caption.count <= 80 else { throw ToolExecutionError.message("拼图标题最多 80 个字符，请在参数设置中缩短。") }
        var settings = CollageSettings()
        settings.mode = mode; settings.ratio = ratio; settings.template = template
        settings.fitImages = values["fitImages"] == "true"
        settings.spacing = number(values,"spacing"); settings.margin = number(values,"margin")
        settings.background = background; settings.resolution = Double(values["resolution"] ?? "2400") ?? 2400
        settings.filter = filter; settings.brightness = number(values,"brightness")
        settings.contrast = Double(values["contrast"] ?? "1") ?? 1
        settings.saturation = Double(values["saturation"] ?? "1") ?? 1
        settings.caption = caption; settings.captionAtTop = values["captionAtTop"] == "true"
        settings.captionSize = Double(values["captionSize"] ?? "64") ?? 64
        settings.format = format; settings.jpegQuality = Double(values["jpegQuality"] ?? "0.9") ?? 0.9
        return settings
    }
}
