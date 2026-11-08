import Foundation
import AppKit

/// Written only by local execution or explicit user association, never by AI tool JSON.
struct RitoResultFile: Codable, Equatable, Sendable {
    static let safeExtensions: Set<String> = ["pdf","jpg","jpeg","png","heic","bmp","tiff","tif","webp","docx","txt","srt","vtt","mp4","mov","gif"]
    let url: URL
    var bookmarkData: Data? = nil

    static func capture(_ url: URL) -> Self {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let scoped = access ? try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) : nil
        let bookmark = scoped ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        return .init(url: url, bookmarkData: bookmark)
    }
    func resolvedURL() throws -> URL {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { throw RitoResultFileError.unavailable }
        var resolved = url
        if let bookmarkData {
            let choices: [URL.BookmarkResolutionOptions] = [
                [.withoutUI, .withoutMounting], [.withSecurityScope, .withoutUI, .withoutMounting]
            ]
            for options in choices {
                var stale = false
                if let value = try? URL(resolvingBookmarkData: bookmarkData, options: options,
                    relativeTo: nil, bookmarkDataIsStale: &stale) {
                    resolved = value; break
                }
            }
        }
        guard resolved.isFileURL, (resolved.host == nil || resolved.host == "" || resolved.host == "localhost"), Self.safeExtensions.contains(resolved.pathExtension.lowercased()) else { throw RitoResultFileError.unavailable }
        let access = resolved.startAccessingSecurityScopedResource()
        defer { if access { resolved.stopAccessingSecurityScopedResource() } }
        try FileOrganizerService.noLinks(resolved)
        guard (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.isReadableFile(atPath: resolved.path) else { throw RitoResultFileError.unavailable }
        return resolved
    }
}
enum RitoResultFileError: LocalizedError {
    case unavailable, copyFailed, openFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: "结果文件当前不可访问，可能已移动或删除。请重新关联结果文件。"
        case .copyFailed: "无法复制文件到剪贴板，请重试。"
        case .openFailed: "无法打开文件，请检查默认阅读器或重新关联文件。"
        }
    }
}
@MainActor protocol RitoFilePasteboard {
    func writeFile(_ url: URL) -> Bool
}
@MainActor struct RitoSystemFilePasteboard: RitoFilePasteboard {
    func writeFile(_ url: URL) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.writeObjects([url as NSURL])
    }
}
@MainActor enum RitoResultFileActions {
    static func copy(_ file: RitoResultFile, to pasteboard: any RitoFilePasteboard = RitoSystemFilePasteboard()) throws {
        let url = try file.resolvedURL()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard pasteboard.writeFile(url) else { throw RitoResultFileError.copyFailed }
    }
    static func open(_ file: RitoResultFile) throws {
        let url = try file.resolvedURL()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard NSWorkspace.shared.open(url) else { throw RitoResultFileError.openFailed }
    }
    static func reveal(_ file: RitoResultFile) throws {
        let url = try file.resolvedURL()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
