import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A single serial worker prevents rapid slider updates from spawning simultaneous full-image renders.
private actor CollageWorker {
    func prepare(_ urls: [URL]) -> ([CollagePhoto], [String]) {
        var photos: [CollagePhoto] = [], errors: [String] = []
        for url in urls {
            if Task.isCancelled { break }
            do { photos.append(try autoreleasepool { try CollageService.prepare(url) }) }
            catch { errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        return (photos, errors)
    }
    func preview(_ photos: [CollagePhoto], settings: CollageSettings) throws -> CGImage {
        let geometry = try CollageService.geometry(sizes: photos.map(\.size),settings: settings)
        let aspect = max(geometry.size.width,geometry.size.height)/min(geometry.size.width,geometry.size.height)
        let limit = settings.mode == .grid ? 1100 : min(16384,600*aspect,sqrt(4_000_000*aspect))
        return try CollageService.render(photos: photos, settings: settings, previewMaximum: limit)
    }
    func export(_ photos: [CollagePhoto], settings: CollageSettings, url: URL,
                progress: @Sendable (Double) -> Void) throws {
        try CollageService.export(photos: photos, settings: settings, to: url, progress: progress)
    }
}

@MainActor @Observable
final class CollageViewModel {
    struct Snapshot {
        let settings: CollageSettings
        let photos: [CollagePhoto]
    }
    var settings = CollageSettings() {
        didSet {
            guard settings != oldValue else { return }
            if !restoring { remember(Snapshot(settings: oldValue, photos: photos)) }
            refreshPreview()
        }
    }
    private(set) var photos: [CollagePhoto] = []
    var selectedID: UUID?
    private(set) var preview: CGImage?
    private(set) var isLoading = false
    private(set) var isRendering = false
    private(set) var isSaving = false
    private(set) var progress = 0.0
    private(set) var previewError: String?
    private(set) var errorMessage: String?
    private(set) var statusMessage: String?
    private(set) var savedURL: URL?
    private(set) var undoStack: [Snapshot] = []
    private(set) var redoStack: [Snapshot] = []
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private let worker = CollageWorker()
    @ObservationIgnored private var previewTask: Task<Void,Never>?
    @ObservationIgnored private var importTask: Task<Void,Never>?
    @ObservationIgnored private var saveTask: Task<Void,Never>?
    @ObservationIgnored private var revision = UUID()
    var busy: Bool { isLoading || isSaving }
    var geometry: CollageGeometry? { try? CollageService.geometry(sizes: photos.map(\.size), settings: settings) }
    var canExport: Bool { !busy && !isRendering && preview != nil && previewError == nil }
    var selectedPhoto: CollagePhoto? { photos.first { $0.id == selectedID } }

    private func remember(_ snapshot: Snapshot) {
        undoStack.append(snapshot); if undoStack.count > 30 { undoStack.removeFirst() }
        redoStack.removeAll()
    }
    func undo() {
        guard !busy, let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(settings: settings,photos: photos)); restore(snapshot)
    }
    func redo() {
        guard !busy, let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(settings: settings,photos: photos)); restore(snapshot)
    }
    private func restore(_ snapshot: Snapshot) {
        restoring = true; photos = snapshot.photos; settings = snapshot.settings; restoring = false
        if !photos.contains(where: { $0.id == selectedID }) { selectedID = photos.first?.id }
        refreshPreview()
    }
    func chooseImages() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg,.png,.heic,.tiff,.bmp]
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.message = "按导入顺序排布，最多 \(CollageService.maximumPhotos) 张；可在导入后调整顺序。"
        Task { if await FileDialogs.response(to: panel) == .OK { add(panel.urls) } }
    }
    func add(_ urls: [URL]) {
        guard !busy else { return }
        let existing = Set(photos.map { $0.url.standardizedFileURL })
        var seen = existing
        let incoming = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        guard !incoming.isEmpty else { statusMessage = "这些图片已经在列表中。"; return }
        guard photos.count + incoming.count <= CollageService.maximumPhotos else {
            errorMessage = "一次最多 \(CollageService.maximumPhotos) 张图片，当前已有 \(photos.count) 张。请减少选择。"; return
        }
        isLoading = true; errorMessage = nil; statusMessage = nil
        ProcessingActivity.setActive(true, owner: ObjectIdentifier(self))
        importTask = Task {
            let (loaded,errors) = await worker.prepare(incoming)
            if !loaded.isEmpty {
                remember(Snapshot(settings: settings,photos: photos))
                photos += loaded; selectedID = loaded.first?.id
                refreshPreview()
            }
            errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
            isLoading = false; ProcessingActivity.setActive(false, owner: ObjectIdentifier(self))
        }
    }
    func move(_ id: UUID, by delta: Int) {
        guard !busy, let index = photos.firstIndex(where: { $0.id == id }),
              photos.indices.contains(index+delta) else { return }
        remember(Snapshot(settings: settings,photos: photos))
        photos.swapAt(index,index+delta); refreshPreview()
    }
    func remove(_ id: UUID) {
        guard !busy else { return }
        remember(Snapshot(settings: settings,photos: photos)); photos.removeAll { $0.id == id }
        if selectedID == id { selectedID = photos.first?.id }; refreshPreview()
    }
    func clear() {
        guard !busy, !photos.isEmpty else { return }
        remember(Snapshot(settings: settings,photos: photos)); photos.removeAll(); selectedID = nil
        errorMessage = nil; statusMessage = nil; refreshPreview()
    }
    func crop(zoom: Double? = nil, panX: Double? = nil, panY: Double? = nil) {
        guard !busy, let index = photos.firstIndex(where: { $0.id == selectedID }) else { return }
        remember(Snapshot(settings: settings,photos: photos))
        var photo = photos[index]
        if let zoom { photo.zoom = zoom }; if let panX { photo.panX = panX }; if let panY { photo.panY = panY }
        photos[index] = photo; refreshPreview()
    }
    func resetAdjustments() {
        var value = settings; value.filter = .original; value.brightness = 0; value.contrast = 1; value.saturation = 1
        settings = value
    }
    private func refreshPreview() {
        previewTask?.cancel(); revision = UUID(); let token = revision
        previewError = nil; statusMessage = nil
        guard !photos.isEmpty else { preview = nil; isRendering = false; return }
        let inputs = photos, options = settings
        isRendering = true
        previewTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(180))
                let image = try await worker.preview(inputs, settings: options)
                guard token == revision, !Task.isCancelled else { return }
                preview = image; isRendering = false
            } catch {
                guard token == revision else { return }
                isRendering = false; preview = nil
                if !(error is CancellationError) { previewError = error.localizedDescription }
            }
        }
    }

    func save() {
        guard canExport else { return }
        isSaving = true; errorMessage = nil; statusMessage = nil; progress = 0
        let inputs = photos, options = settings
        let panel = NSSavePanel()
        panel.allowedContentTypes = options.format == .png ? [.png] : [.jpeg]
        panel.nameFieldStringValue = "锐途_\(options.mode == .grid ? "拼图" : "长图拼接").\(options.format.fileExtension)"
        panel.canCreateDirectories = true; panel.message = "保存为新图片，原始照片保留。"
        saveTask = Task {
            defer { isSaving = false; ProcessingActivity.setActive(false,owner: ObjectIdentifier(self)) }
            let response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
            guard response == .OK, let url = panel.url else { return }
            ProcessingActivity.setActive(true,owner: ObjectIdentifier(self))
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                try await worker.export(inputs, settings: options, url: url) { [weak self] value in
                    Task { @MainActor in self?.progress = value }
                }
                savedURL = url; progress = 1; statusMessage = "已保存 \(url.lastPathComponent)，原图保留。"
                HistoryService().addRecord(toolName: "拼图",operationType: options.mode.rawValue,fileCount: inputs.count,
                    inputFileNames: inputs.map { $0.url.lastPathComponent },status: "成功",
                    inputSize: inputs.reduce(0) { $0 + FileUtils.fileSize(of: $1.url) },
                    outputSize: FileUtils.fileSize(of: url),
                    descriptionText: "\(options.mode.rawValue) · \(options.format.rawValue) · \(url.path)")
            } catch {
                if error is CancellationError { statusMessage = "已停止导出，原图保留。" }
                else { errorMessage = error.localizedDescription }
            }
        }
    }
    func cancelExport() { saveTask?.cancel() }
}
