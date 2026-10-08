import Foundation
import Observation

/// 元数据单独持久化；不保存输入文件内容，不自动恢复上次未结束的操作。
actor FileTaskStore {
    private let url: URL
    private var lastRevision = 0
    init(url: URL) { self.url = url }
    func save(_ records: [FileTaskRecord], revision: Int) throws {
        guard revision > lastRevision else { return }
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        lastRevision = revision
    }
}

@MainActor @Observable
final class FileTaskManager {
    static let shared = FileTaskManager(storageURL: defaultStorageURL)
    static var defaultStorageURL: URL? {
        if ProcessInfo.processInfo.environment["RUITU_TEST_MODE"] == "1" { return nil }
        let root = ProcessInfo.processInfo.environment["RUITU_WORK_DIRECTORY"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return root?.appendingPathComponent("RuiTuOfficeMaster/Tasks.json")
    }
    private(set) var records: [FileTaskRecord] = []
    private(set) var persistenceError: String?
    private(set) var exportMessages: [UUID: String] = [:]
    private(set) var exportErrors: [UUID: String] = [:]
    private(set) var savingIDs: Set<UUID> = []
    private var store: FileTaskStore?
    private var revision = 0
    private var persistTask: Task<Void, Never>?
    private var jobs: [UUID: Job] = [:]
    private var activeID: UUID?
    private var worker: Task<Void, Never>?
    struct Job {
        let operation: @Sendable (URL) async throws -> FileTaskOutput
        let onChange: @MainActor (FileTaskRecord) -> Void
    }
    var activeCount: Int { records.filter { $0.state.isActive }.count }
    var runningCount: Int { records.filter { $0.state == .running }.count }

    init(storageURL: URL? = nil) {
        store = storageURL.map(FileTaskStore.init)
        guard let url = storageURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            records = Array(try JSONDecoder().decode([FileTaskRecord].self, from: Data(contentsOf: url)).prefix(100))
            for i in records.indices where records[i].state.isActive {
                records[i].state = .interrupted; records[i].endedAt = Date()
                for j in records[i].files.indices where records[i].files[j].state.isActive {
                    records[i].files[j].state = .interrupted
                    records[i].files[j].error = "上次运行未结束，请返回对应工具重新选择文件处理。"
                }
            }
        } catch {
            store = nil
            persistenceError = "任务记录读取失败，本次运行不会覆盖原记录文件：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func enqueue(tool: String, configuration: String, sources: [URL],
                 operation: @escaping @Sendable (URL) async throws -> FileTaskOutput,
                 onChange: @escaping @MainActor (FileTaskRecord) -> Void = { _ in }) -> UUID {
        var seen = Set<URL>()
        let unique = sources.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        var record = FileTaskRecord(tool: tool, configuration: configuration, sources: unique)
        if unique.isEmpty { record.state = .failed; record.endedAt = Date() }
        records.insert(record, at: 0)
        jobs[record.id] = Job(operation: operation, onChange: onChange)
        trimHistory()
        syncActivity(); changed(record.id); startNext()
        return record.id
    }

    deinit { ProcessingActivity.setActive(false, owner: ObjectIdentifier(self)) }

    func record(_ id: UUID) -> FileTaskRecord? { records.first { $0.id == id } }
    func canRetry(_ id: UUID) -> Bool {
        guard let record = record(id) else { return false }
        return !record.state.isActive && record.retryCount > 0 && jobs[id] != nil && !savingIDs.contains(id)
    }
    func retry(_ id: UUID) {
        guard canRetry(id), let i = records.firstIndex(where: { $0.id == id }) else { return }
        for j in records[i].files.indices where [.failed, .cancelled].contains(records[i].files[j].state) {
            records[i].files[j].state = .waiting; records[i].files[j].error = nil
        }
        records[i].state = .waiting; records[i].cancellationRequested = false; records[i].endedAt = nil
        syncActivity(); changed(id); startNext()
    }
    func cancel(_ id: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].state.isActive else { return }
        records[i].cancellationRequested = true
        if activeID == id { worker?.cancel(); changed(id) }
        else { finish(id, cancelled: true) }
    }

    /// 串行执行图片批处理，避免大图任务互相争抢内存；排队期间也可取消。
    private func startNext() {
        guard activeID == nil, let queued = records.last(where: { $0.state == .waiting }),
              let job = jobs[queued.id], let i = records.firstIndex(where: { $0.id == queued.id }) else { return }
        let id = queued.id
        activeID = id; records[i].state = .running; records[i].startedAt = records[i].startedAt ?? Date()
        changed(id)
        let pending = records[i].files.filter { $0.state == .waiting }
        worker = Task { [weak self] in
            let background = Task.detached(priority: .userInitiated) { [weak self] in
                for entry in pending {
                    if Task.isCancelled { return true }
                    await self?.beginFile(id, entryID: entry.id)
                    do {
                        try Task.checkCancellation()
                        let output = try await job.operation(entry.source)
                        // 已成功写完的文件保留；下一项在取消检查点停止。
                        await self?.completeFile(id, entryID: entry.id, output: output, error: nil)
                    } catch {
                        if Task.isCancelled || error is CancellationError { return true }
                        await self?.completeFile(id, entryID: entry.id, output: nil, error: error.localizedDescription)
                    }
                }
                return false
            }
            let cancelled = await withTaskCancellationHandler(operation: { await background.value }, onCancel: { background.cancel() })
            self?.finish(id, cancelled: cancelled || Task.isCancelled)
        }
    }
    private func beginFile(_ id: UUID, entryID: UUID) {
        guard let i = records.firstIndex(where: { $0.id == id }),
              let j = records[i].files.firstIndex(where: { $0.id == entryID }) else { return }
        records[i].files[j].state = .running; records[i].files[j].attempts += 1
        changed(id)
    }
    private func completeFile(_ id: UUID, entryID: UUID, output: FileTaskOutput?, error: String?) {
        guard let i = records.firstIndex(where: { $0.id == id }),
              let j = records[i].files.firstIndex(where: { $0.id == entryID }) else { return }
        records[i].files[j].output = output; records[i].files[j].error = error
        records[i].files[j].state = output == nil ? .failed : .completed
        changed(id)
    }
    private func finish(_ id: UUID, cancelled: Bool) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        if cancelled {
            for j in records[i].files.indices where records[i].files[j].state.isActive {
                records[i].files[j].state = .cancelled
            }
            records[i].state = .cancelled
        } else {
            records[i].state = records[i].failed == 0 ? .completed : (records[i].succeeded == 0 ? .failed : .partial)
        }
        records[i].endedAt = Date()
        if activeID == id { activeID = nil; worker = nil }
        syncActivity(); changed(id); startNext()
    }
    private func syncActivity() {
        ProcessingActivity.setActive(activeCount > 0 || !savingIDs.isEmpty, owner: ObjectIdentifier(self))
    }
    private func changed(_ id: UUID) {
        if let record = record(id) { jobs[id]?.onChange(record) }
        persist()
    }
    private func persist() {
        guard let store else { return }
        persistTask?.cancel()
        revision += 1
        let currentRevision = revision
        // 合并短时间内的状态更新，避免大批量任务每完成一项就重写整份记录。
        persistTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self else { return }
            let snapshot = records
            do { try await store.save(snapshot, revision: currentRevision) }
            catch { persistenceError = "任务记录保存失败：\(error.localizedDescription)" }
        }
    }
    private func trimHistory() {
        while records.count > 100, let i = records.lastIndex(where: { !$0.state.isActive && !savingIDs.contains($0.id) }) {
            jobs.removeValue(forKey: records[i].id); exportMessages.removeValue(forKey: records[i].id); exportErrors.removeValue(forKey: records[i].id); records.remove(at: i)
        }
    }
    func clearFinished() {
        let removed = records.filter { !$0.state.isActive && !savingIDs.contains($0.id) }.map(\.id)
        records.removeAll { removed.contains($0.id) }
        for id in removed { jobs.removeValue(forKey: id); exportMessages.removeValue(forKey: id); exportErrors.removeValue(forKey: id) }
        persist()
    }
    func saveResults(_ id: UUID) async {
        guard let record = record(id), !record.state.isActive, !savingIDs.contains(id) else { return }
        let entries = record.files.filter { $0.output != nil }
        guard !entries.isEmpty else { return }
        savingIDs.insert(id); syncActivity()
        defer { savingIDs.remove(id); syncActivity() }
        let sources = entries.compactMap { entry in
            [entry.output?.url, entry.savedURL].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let report = await ResultExporter.save(sources) { recordExport(id, report: report) }
    }
    func recordExport(_ id: UUID, report: ExportReport) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        for saved in report.savedFiles {
            if let j = records[i].files.firstIndex(where: { $0.output?.url == saved.source || $0.savedURL == saved.source }) {
                records[i].files[j].savedURL = saved.destination
            }
        }
        exportMessages[id] = report.message
        exportErrors[id] = report.errors.isEmpty ? nil : report.errors.joined(separator: "\n")
        persist()
    }
}
