import Foundation
import PDFKit
import AppKit

/// 用于确认预览仍对应原文档；不把 PDFDocument 跨线程传递。
struct PDFPreviewVersion: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modified: Date
    static func read(_ url: URL) -> Self? {
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = values[.systemNumber] as? NSNumber,
              let inode = values[.systemFileNumber] as? NSNumber,
              let size = values[.size] as? NSNumber,
              let modified = values[.modificationDate] as? Date else { return nil }
        return Self(device: device.uint64Value, inode: inode.uint64Value, size: size.uint64Value, modified: modified)
    }
}

struct PDFPreviewMetadata: Sendable {
    let pageCount: Int
    let version: PDFPreviewVersion
}

enum PDFPreviewError: LocalizedError {
    case changed, renderFailed
    var errorDescription: String? {
        switch self {
        case .changed: "文件已变化，请重新加载预览并确认页码范围。"
        case .renderFailed: "无法生成此页预览，可以重试或查看其他页面。"
        }
    }
}

/// 在后台串行读取文档，每次只渲染一页，避免一次生成整本 PDF 的图片。
actor PDFPreviewReader {
    private var document: PDFDocument?
    private var sourceURL: URL?
    private var version: PDFPreviewVersion?

    func load(_ url: URL) throws -> PDFPreviewMetadata {
        document = nil; sourceURL = nil; version = nil
        guard let before = PDFPreviewVersion.read(url), let pdf = PDFDocument(url: url) else {
            throw PDFError.invalidSource(url: url)
        }
        guard !pdf.isLocked else { throw PDFError.sourceEncrypted(url: url) }
        guard pdf.pageCount > 0 else { throw PDFError.noPages }
        guard before == PDFPreviewVersion.read(url) else { throw PDFPreviewError.changed }
        document = pdf; sourceURL = url; version = before
        return PDFPreviewMetadata(pageCount: pdf.pageCount, version: before)
    }

    func render(_ url: URL, page: Int, expectedVersion: PDFPreviewVersion) throws -> Data {
        guard PDFPreviewVersion.read(url) == expectedVersion else { throw PDFPreviewError.changed }
        if sourceURL != url || version != expectedVersion { _ = try load(url) }
        guard let document, (1...document.pageCount).contains(page), let pdfPage = document.page(at: page - 1) else {
            throw PDFError.invalidPageRange("第 \(page) 页")
        }
        let image = pdfPage.thumbnail(of: NSSize(width: 1200, height: 1600), for: .cropBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { throw PDFPreviewError.renderFailed }
        guard PDFPreviewVersion.read(url) == expectedVersion else { throw PDFPreviewError.changed }
        return data
    }

    func clear() { document = nil; sourceURL = nil; version = nil }
}

@MainActor @Observable
final class PDFSplitPreviewViewModel {
    private(set) var selectedURL: URL?
    private(set) var pageCount: Int?
    private(set) var currentPage = 1
    private(set) var image: NSImage?
    private(set) var isLoadingDocument = false
    private(set) var isRenderingPage = false
    private(set) var documentError: String?
    private(set) var pageError: String?
    private(set) var jumpError: String?
    private(set) var version: PDFPreviewVersion?
    @ObservationIgnored private let reader = PDFPreviewReader()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var documentRequest = UUID()
    @ObservationIgnored private var pageRequest = UUID()

    var isReady: Bool { pageCount != nil && !isLoadingDocument && documentError == nil }
    var sourceIsCurrent: Bool {
        guard let selectedURL, let version else { return false }
        return PDFPreviewVersion.read(selectedURL) == version
    }

    func setFiles(_ files: [URL]) {
        let next = selectedURL.flatMap { files.contains($0) ? $0 : nil } ?? files.first
        guard next != selectedURL else { return }
        select(next)
    }

    func select(_ url: URL?) {
        loadTask?.cancel(); renderTask?.cancel()
        documentRequest = UUID(); pageRequest = UUID()
        selectedURL = url; pageCount = nil; currentPage = 1; version = nil; image = nil
        documentError = nil; pageError = nil; jumpError = nil
        isLoadingDocument = url != nil; isRenderingPage = false
        guard let url else {
            let reader = reader
            loadTask = Task { await reader.clear() }
            return
        }
        let request = documentRequest; let reader = reader
        loadTask = Task { [weak self] in
            do {
                let metadata = try await reader.load(url)
                guard let self, !Task.isCancelled, self.documentRequest == request else { return }
                self.pageCount = metadata.pageCount; self.version = metadata.version
                self.isLoadingDocument = false
                self.goToPage(1)
            } catch {
                guard let self, !Task.isCancelled, self.documentRequest == request else { return }
                self.documentError = error.localizedDescription; self.isLoadingDocument = false
            }
        }
    }

    func reload() { select(selectedURL) }

    func jump(to text: String) {
        guard let count = pageCount, let page = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...count).contains(page) else {
            jumpError = pageCount.map { "请输入 1 到 \($0) 之间的页码。" } ?? "请先等待文档加载完成。"
            return
        }
        goToPage(page)
    }

    func goToPage(_ page: Int) {
        guard let url = selectedURL, let version, let count = pageCount, (1...count).contains(page) else { return }
        renderTask?.cancel(); pageRequest = UUID()
        currentPage = page; image = nil; pageError = nil; jumpError = nil; isRenderingPage = true
        let request = pageRequest; let documentID = documentRequest; let reader = reader
        renderTask = Task { [weak self] in
            do {
                let data = try await reader.render(url, page: page, expectedVersion: version)
                guard let self, !Task.isCancelled, self.pageRequest == request, self.documentRequest == documentID else { return }
                self.image = NSImage(data: data)
                if self.image == nil { self.pageError = PDFPreviewError.renderFailed.localizedDescription }
                self.isRenderingPage = false
            } catch {
                guard let self, !Task.isCancelled, self.pageRequest == request, self.documentRequest == documentID else { return }
                self.pageError = error.localizedDescription
                if case PDFPreviewError.changed = error { self.documentError = error.localizedDescription }
                self.isRenderingPage = false
            }
        }
    }
}
