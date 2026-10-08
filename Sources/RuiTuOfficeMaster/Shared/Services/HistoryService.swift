import SwiftData
import Foundation

/// 历史记录持久化服务 — 自管理 ModelContainer，对调用方零侵入
@MainActor
struct HistoryService {
    private static let container: ModelContainer? = {
        try? {
            if ProcessInfo.processInfo.environment["RUITU_TEST_MODE"] == "1" {
                return try ModelContainer(for: HistoryRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            }
            if let path = ProcessInfo.processInfo.environment["RUITU_WORK_DIRECTORY"] {
                let url = URL(fileURLWithPath: path).appendingPathComponent("History.store")
                return try ModelContainer(for: HistoryRecord.self, configurations: ModelConfiguration(url: url))
            }
            return try ModelContainer(for: HistoryRecord.self)
        }()
    }()

    private let context: ModelContext?

    init() {
        guard let container = HistoryService.container else { context = nil; return }
        context = ModelContext(container)
    }

    // MARK: - 写入

    func addRecord(toolName: String, operationType: String, fileCount: Int,
                   inputFileNames: [String], status: String, inputSize: Int64,
                   outputSize: Int64, descriptionText: String) {
        guard let context else { return }
        let record = HistoryRecord(
            toolName: toolName,
            operationType: operationType,
            fileCount: fileCount,
            inputFileNames: inputFileNames,
            status: status,
            inputSize: inputSize,
            outputSize: outputSize,
            descriptionText: descriptionText
        )
        context.insert(record)
        try? context.save()
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
        NotificationCenter.default.post(name: .cacheDidChange, object: nil)
    }

    // MARK: - 查询

    func fetchAll() -> [HistoryRecord] {
        guard let context else { return [] }
        let descriptor = FetchDescriptor<HistoryRecord>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func fetchFiltered(toolName: String?, searchText: String) -> [HistoryRecord] {
        var all = fetchAll()
        if let tool = toolName {
            all = all.filter { $0.toolName == tool }
        }
        if !searchText.isEmpty {
            all = all.filter { record in
                record.toolName.localizedCaseInsensitiveContains(searchText) ||
                record.operationType.localizedCaseInsensitiveContains(searchText) ||
                record.descriptionText.localizedCaseInsensitiveContains(searchText) ||
                record.inputFileNames.contains { $0.localizedCaseInsensitiveContains(searchText) }
            }
        }
        return all
    }

    // MARK: - 删除

    func deleteRecord(_ record: HistoryRecord) {
        guard let context else { return }
        context.delete(record)
        try? context.save()
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
    }

    func clearAll() {
        guard let context else { return }
        let all = fetchAll()
        for record in all { context.delete(record) }
        try? context.save()
        NotificationCenter.default.post(name: .historyDidChange, object: nil)
        NotificationCenter.default.post(name: .cacheDidChange, object: nil)
    }
}
