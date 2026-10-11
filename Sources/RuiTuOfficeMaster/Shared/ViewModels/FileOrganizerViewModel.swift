import Foundation
import AppKit
import SwiftUI

@MainActor @Observable
final class FileOrganizerViewModel {
    var roots: [URL] = []
    var destination: URL?
    var recursive = true
    var excluded: [URL] = []
    var mode: OrganizerMode = .copy
    var conflict: OrganizerConflict = .number
    private(set) var plan: OrganizerPlan?
    private(set) var records: [OrganizerJournal] = []
    private(set) var journal: OrganizerJournal?
    private(set) var busy = false { didSet { ProcessingActivity.setActive(busy, owner: ObjectIdentifier(self)) } }
    private(set) var isScanning = false
    private(set) var isUndoing = false
    private(set) var isDeletingRecord = false
    private(set) var scanned = 0
    private(set) var completed = 0
    private(set) var currentName = ""
    var errorMessage: String?
    var statusMessage: String?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private let store: OrganizerJournalStore
    init(store: OrganizerJournalStore = .standard) { self.store = store }
    var configuration: OrganizerConfiguration? {
        destination.map { OrganizerConfiguration(roots: roots.sorted { $0.path < $1.path }, destination: $0.standardizedFileURL, recursive: recursive, excluded: excluded, mode: mode, conflict: conflict) }
    }
    var canExecute: Bool { !busy && plan?.actionable.isEmpty == false && plan?.configuration == configuration }
    var canUndo: Bool { !busy && (journal?.undoableCount ?? 0) > 0 }
    var canDeleteRecord: Bool { !busy && journal != nil }
    func invalidate() { guard !busy else { return }; plan = nil; errorMessage = nil; statusMessage = nil }
    func addRoots(_ urls: [URL]) {
        guard !busy else { return }
        var rejected: [String] = []
        for raw in urls {
            let url = raw.standardizedFileURL.resolvingSymlinksInPath()
            guard url.isFileURL, (try? OrganizerDirectoryIdentity.read(url)) != nil,
                  (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) != true else { rejected.append(raw.lastPathComponent); continue }
            if !roots.contains(url) { roots.append(url) }
        }
        if destination == nil, let first = roots.first { destination = first.appendingPathComponent("整理结果") }
        invalidate()
        if !rejected.isEmpty { errorMessage = "仅接受普通文件夹，未添加：" + rejected.joined(separator: "、") }
    }
    func chooseRoots() {
        guard !busy else { return }
        Task {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
            panel.prompt = "添加文件夹"
            if await FileDialogs.response(to: panel) == .OK, !busy { addRoots(panel.urls) }
        }
    }
    func chooseDestination() {
        guard !busy else { return }
        Task {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.prompt = "整理到这里"; panel.message = "选择独立文件夹或源文件夹里的“整理结果”，不允许直接整理到源目录及其上级。"
            if await FileDialogs.response(to: panel) == .OK, !busy, let url = panel.url {
                destination = url.standardizedFileURL.resolvingSymlinksInPath(); invalidate()
            }
        }
    }
    func chooseExclusions() {
        guard !busy else { return }
        Task {
            let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
            panel.prompt = "排除这些文件夹"
            if await FileDialogs.response(to: panel) == .OK, !busy {
                for raw in panel.urls { let url = raw.standardizedFileURL.resolvingSymlinksInPath(); if !excluded.contains(url) { excluded.append(url) } }
                invalidate()
            }
        }
    }
    func removeRoot(_ url: URL) { guard !busy else { return }; roots.removeAll { $0 == url }; invalidate() }
    func removeExclusion(_ url: URL) { guard !busy else { return }; excluded.removeAll { $0 == url }; invalidate() }
    func clear() { guard !busy else { return }; roots = []; destination = nil; excluded = []; invalidate() }
    func selectRecord(_ id: UUID) { guard !busy else { return }; journal = records.first { $0.id == id }; statusMessage = nil; errorMessage = nil }
    func deleteRecord(_ id: UUID) async {
        guard !busy, journal?.id == id else { return }
        let store = store
        busy = true; isDeletingRecord = true; errorMessage = nil; statusMessage = nil
        defer { busy = false; isDeletingRecord = false }
        do {
            try await Task.detached { try store.deleteRecord(id) }.value
        } catch {
            errorMessage = "删除整理记录失败：\(error.localizedDescription)"
            return
        }
        records.removeAll { $0.id == id }
        journal = records.first
        statusMessage = "整理记录已删除，原文件和整理后的文件均保留。"
        do {
            records = try await Task.detached { try store.recent() }.value
            journal = records.first
        } catch {
            errorMessage = "记录已删除，但其余记录读取失败：\(error.localizedDescription)"
        }
    }
    func loadRecords() async {
        guard !busy else { return }; let store = store
        do {
            let values = try await Task.detached { try store.recent() }.value
            guard !busy else { return }; records = values
            if journal == nil { journal = values.first }
        } catch { errorMessage = "整理记录读取失败：\(error.localizedDescription)" }
    }
    func preview() {
        guard !busy, let settings = configuration, !roots.isEmpty else { return }
        plan = nil; busy = true; isScanning = true; scanned = 0; errorMessage = nil; statusMessage = nil
        worker = Task {
            let task = Task.detached(priority: .userInitiated) { [self] in
                try FileOrganizerService.preview(settings) { count in
                    Task { @MainActor [weak self] in guard let self, self.isScanning else { return }; self.scanned = count }
                }
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                if !Task.isCancelled {
                    plan = result
                    if result.items.isEmpty { statusMessage = "没有可整理的普通文件。请检查递归范围和排除设置。" }
                }
            } catch is CancellationError { statusMessage = "扫描已停止，未执行文件操作。" }
            catch { errorMessage = error.localizedDescription }
            busy = false; isScanning = false; worker = nil
        }
    }
    func execute() {
        guard canExecute, let plan else { return }
        run(undo: false, plan: plan)
    }
    func undo() { guard canUndo else { return }; run(undo: true, plan: nil) }
    private func run(undo: Bool, plan: OrganizerPlan?) {
        let previous = journal, store = store
        busy = true; isUndoing = undo; completed = 0; currentName = ""; errorMessage = nil; statusMessage = nil
        worker = Task {
            let task = Task.detached(priority: .userInitiated) { [self] in
                let progress: @Sendable (Int, String) -> Void = { count, name in
                    Task { @MainActor [weak self] in guard let self, self.busy else { return }; self.completed = count; self.currentName = name }
                }
                return try undo ? FileOrganizerService.undo(previous!, store: store, progress: progress)
                    : FileOrganizerService.execute(plan!, store: store, progress: progress)
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
                journal = result; statusMessage = (undo ? "撤销结果：" : "整理结果：") + result.summary
                errorMessage = result.error
                HistoryService().addRecord(toolName: "文件整理", operationType: undo ? "撤销整理" : result.configuration.mode.rawValue,
                    fileCount: result.items.count, inputFileNames: result.items.map { $0.source.lastPathComponent },
                    status: result.failureCount > 0 || result.error != nil ? "部分失败" : result.stopped ? "已停止" : "完成",
                    inputSize: 0, outputSize: 0, descriptionText: statusMessage ?? "")
            } catch is CancellationError { statusMessage = "任务已停止，请查看记录中的实际完成项。" }
            catch { errorMessage = error.localizedDescription; if !undo { journal = nil } }
            self.plan = nil; currentName = ""
            // The persisted record remains authoritative if execution stopped after publishing a file.
            do { records = try await Task.detached { try store.recent() }.value; journal = records.first(where: { $0.id == journal?.id }) ?? records.first }
            catch { errorMessage = "整理记录读取失败：\(error.localizedDescription)" }
            busy = false; isUndoing = false; worker = nil
        }
    }
    func cancel() { guard busy else { return }; worker?.cancel() }
    func revealDestination() {
        if let url = journal?.configuration.destination ?? destination, FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
    }
}
