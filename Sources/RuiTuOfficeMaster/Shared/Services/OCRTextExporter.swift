import Foundation

struct OCRTextExportReport: Sendable {
    var savedURLs: [URL] = []
    var renamedCount = 0
    var skippedCount = 0
    var errors: [String] = []

    var message: String {
        "已分别保存 \(savedURLs.count) 个 TXT"
            + (renamedCount > 0 ? "，\(renamedCount) 个重名文件已自动编号" : "")
            + (skippedCount > 0 ? "，跳过 \(skippedCount) 张无文字图片" : "")
            + (errors.isEmpty ? "" : "，\(errors.count) 个失败")
    }
}

enum OCRTextExporter {
    static func fileName(for result: OCRImageResult) -> String {
        // 保留源扩展名，区分同名的 PNG/JPG；为后缀和自动编号留出空间。
        var name = result.fileName
        if name.utf8.count > 210 {
            let ext = result.sourceURL.pathExtension
            let suffix = !ext.isEmpty && ext.utf8.count <= 20 ? "." + ext : ""
            var stem = result.sourceURL.deletingPathExtension().lastPathComponent
            while (stem + suffix).utf8.count > 210 { stem.removeLast() }
            name = stem + suffix
        }
        return name + "_识别结果.txt"
    }

    static func export(_ results: [OCRImageResult], to directory: URL) -> OCRTextExportReport {
        var report = OCRTextExportReport()
        report.skippedCount = results.filter { !$0.hasText }.count
        let stage = FileManager.default.temporaryDirectory.appendingPathComponent("ruitu-ocr-export-\(UUID())")
        defer { try? FileManager.default.removeItem(at: stage) }
        do { try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true) }
        catch { report.errors.append("无法准备导出：\(error.localizedDescription)"); return report }
        for result in results where result.hasText {
            do {
                try Task.checkCancellation()
                // 每张使用独立临时路径，避免 URL 的缓存文件大小影响安全复制校验。
                let payload = stage.appendingPathComponent(UUID().uuidString + ".txt")
                try result.text.write(to: payload, atomically: true, encoding: .utf8)
                let proposed = directory.appendingPathComponent(fileName(for: result))
                let saved = try FileUtils.safeCopy(from: payload, to: proposed)
                report.savedURLs.append(saved)
                if saved.lastPathComponent != proposed.lastPathComponent { report.renamedCount += 1 }
            } catch is CancellationError {
                report.errors.append("导出已停止，剩余文件未保存"); break
            } catch { report.errors.append("\(result.fileName)：\(error.localizedDescription)") }
        }
        return report
    }
}
