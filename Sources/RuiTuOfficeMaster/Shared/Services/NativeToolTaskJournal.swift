import Foundation

actor ToolExecutionGate {
    static let shared = ToolExecutionGate()
    private var busy = false
    func enter() -> Bool { guard !busy else { return false }; busy = true; return true }
    func leave() { busy = false }
}
struct NativeToolTaskRecord: Codable, Sendable, Identifiable {
    var id = UUID()
    var date = Date()
    let tool: String
    let output: URL?
    var state: String
    var results: [RToolAIResult]
}
enum NativeToolTaskJournal {
    private static let lock = NSLock()
    static var directory: URL? {
        if ProcessInfo.processInfo.environment["RUITU_TEST_MODE"] == "1" { return nil }
        let root = ProcessInfo.processInfo.environment["RUITU_WORK_DIRECTORY"].map { URL(fileURLWithPath:$0) }
            ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first
        return root?.appendingPathComponent("RuiTuOfficeMaster/ToolTasks")
    }
    /// Local recovery metadata only. No prompts, credentials, passwords or source-file contents.
    @discardableResult static func save(_ record: NativeToolTaskRecord) -> Bool {
        guard let directory else { return true }
        lock.lock(); defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let data = try JSONEncoder().encode(record)
            try data.write(to:directory.appendingPathComponent(record.id.uuidString + ".json"),options:.atomic)
            return true
        } catch {
            // Never log paths or tool parameters; output files remain in the selected location.
            print("Tool task journal unavailable")
            return false
        }
    }
    static func load() -> [NativeToolTaskRecord] {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil) else { return [] }
        return files.compactMap { url in (try? Data(contentsOf:url)).flatMap { try? JSONDecoder().decode(NativeToolTaskRecord.self,from:$0) } }.sorted { $0.date > $1.date }.prefix(100).map { record in
            var record = record
            if record.state == "running" { record.state = "interrupted" }
            return record
        }
    }
}
