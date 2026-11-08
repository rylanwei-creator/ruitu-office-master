import Foundation
import PDFKit

struct RitoLocalToolOptions: Sendable {
    var ownerPassword = ""
    var exclusions: [URL] = []
    var collageCrops: [UUID: IDPhotoCrop] = [:]
}

struct RitoPreparedTool: Sendable {
    let call: RitoToolCall
    let urls: [URL]
    let stamps: [OrganizerStamp]
    let destination: URL?
    let destinationIdentity: OrganizerDirectoryIdentity?
    let organizer: OrganizerPlan?
    let summary: [String]
    var parameters: [String: String] = [:]
    var renamePreview: [RenamePreviewItem]? = nil
    var localPassword: String? = nil
    var previewData: Data? = nil
    var localOptions = RitoLocalToolOptions()
}

enum RitoToolExecutor {
    static func prepare(_ call: RitoToolCall, files: [UUID: URL], destination: URL?, localOptions: RitoLocalToolOptions = .init()) throws -> RitoPreparedTool {
        let urls = try call.attachmentIDs.map { id in guard let url = files[id] else { throw RitoToolError.missingFiles }; try FileOrganizerService.noLinks(url); return url }
        let accesses = urls.filter { $0.startAccessingSecurityScopedResource() }
        let folder = destination?.deletingLastPathComponent()
        let access = folder?.startAccessingSecurityScopedResource() ?? false
        defer { accesses.forEach { $0.stopAccessingSecurityScopedResource() }; if access { folder?.stopAccessingSecurityScopedResource() } }
        try Task.checkCancellation()
        let values = try ToolRegistry.lookup(call.operation).values(call.parameters ?? [:])
        switch call.operation {
        case .organize_copy, .organize_move:
            guard let destination else { throw RitoToolError.missingFiles }
            let plan = try FileOrganizerService.preview(.init(roots: urls, destination: destination, recursive: values["recursive"] != "false", excluded: localOptions.exclusions, mode: call.operation == .organize_move ? .move : .copy, conflict: values["conflict"] == "skip" ? .skip : .number))
            let rows = plan.items.map { "\($0.source.lastPathComponent) → \($0.category)/\($0.destination.lastPathComponent)" }
            return .init(call: call, urls: urls, stamps: [], destination: destination, destinationIdentity: nil, organizer: plan,
                summary: ToolRegistry.lookup(call.operation).parameterSummary(values) + ["排除目录：\(localOptions.exclusions.count) 个"] + [(call.operation == .organize_move ? "移动" : "复制") + " \(plan.items.count) 个文件；" + (call.operation == .organize_move ? "源文件路径会改变，可在整理记录撤销。" : "源文件保留。")] + rows)
        case .ocr, .pdf_merge:
            let stamps = try urls.map { try OrganizerStamp.read($0) }
            var rows = urls.map(\.lastPathComponent)
            if call.operation == .pdf_merge {
                let counts = try urls.map { url -> Int in
                    try PDFService().validate(url: url)
                    return PDFDocument(url: url)?.pageCount ?? 0
                }
                rows = zip(urls, counts).map { "\($0.0.lastPathComponent)：\($0.1) 页" }
                rows.append("合并后共 \(counts.reduce(0, +)) 页；保留原 PDF。")
                guard let destination, !FileManager.default.fileExists(atPath: destination.path) else { throw RitoToolError.destinationOccupied }
            } else { rows += ToolRegistry.lookup(call.operation).parameterSummary(values); rows.append("仅在本机读取所列图片并逐图显示文字；不上传识别结果。") }
            return .init(call: call, urls: urls, stamps: stamps, destination: destination,
                destinationIdentity: try destination.map { try OrganizerDirectoryIdentity.read($0.deletingLastPathComponent()) }, organizer: nil, summary: rows, parameters: values)
        default: throw RitoToolError.invalidPlan
        }
    }
    static func execute(_ plan: RitoPreparedTool, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> [RToolAIResult] {
        let accesses = plan.urls.filter { $0.startAccessingSecurityScopedResource() }
        let outputFolder = plan.destination?.deletingLastPathComponent()
        let destinationAccess = outputFolder?.startAccessingSecurityScopedResource() ?? false
        defer { accesses.forEach { $0.stopAccessingSecurityScopedResource() }; if destinationAccess { outputFolder?.stopAccessingSecurityScopedResource() } }
        for (url, stamp) in zip(plan.urls, plan.stamps) { guard try OrganizerStamp.read(url) == stamp else { throw RitoToolError.changed } }
        switch plan.call.operation {
        case .ocr:
            var results: [RToolAIResult] = []
            for (index, url) in plan.urls.enumerated() {
                try Task.checkCancellation()
                let image = try OCRService().loadImage(from: url)
                let text = try await OCRService().recognizeText(from: image, languages:[plan.parameters["language"] ?? "auto"], preprocess:plan.parameters["preprocess"] != "false")
                try Task.checkCancellation()
                results.append(.init(sourceName: url.lastPathComponent, detail: text.isEmpty ? "未识别到文字" : text, previewData: RitoImagePreview.data(from: url)))
                await progress(Double(index + 1) / Double(plan.urls.count))
            }
            return results
        case .pdf_merge:
            guard let destination = plan.destination, let identity = plan.destinationIdentity,
                  try OrganizerDirectoryIdentity.read(destination.deletingLastPathComponent()) == identity else { throw RitoToolError.changed }
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw RitoToolError.destinationOccupied }
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".rito-pdf-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: stage) }
            try PDFService().merge(urls: plan.urls, outputURL: stage, shouldStop: { Task.isCancelled })
            try Task.checkCancellation()
            // FileManager move commits without replacing an existing destination.
            try FileManager.default.moveItem(at: stage, to: destination)
            await progress(1)
            return [.init(sourceName: destination.lastPathComponent, detail: "已合并 \(plan.urls.count) 个 PDF，原文件保留。", fileReference: .capture(destination))]
        case .organize_copy, .organize_move:
            guard let organizer = plan.organizer else { throw RitoToolError.missingFiles }
            let journal = try FileOrganizerService.execute(organizer, store: .standard) { count, _ in
                Task { @MainActor in progress(Double(count) / Double(max(1, organizer.items.count))) }
            }
            let results: [RToolAIResult] = journal.items.map { .init(sourceName: $0.source.lastPathComponent, detail: "\($0.phase.rawValue)：\($0.category)/\($0.destination.lastPathComponent)" + ($0.message.map { "；" + $0 } ?? ""), organizationCategory: $0.category, organizationPhase: $0.phase,failed:$0.phase == .failed) }
            guard !Task.isCancelled, !journal.stopped, journal.items.allSatisfy({ $0.phase == .completed || $0.phase == .skipped }) else {
                throw ToolExecutionFailure(results:results,cancelled:Task.isCancelled || journal.stopped,reason:"整理未全部完成，真实记录及已完成文件已保留；可在文件整理页面检查与撤销。")
            }
            return results
        default: return try await TaskEngine.executeNative(plan, progress: progress)
        }
    }
}
