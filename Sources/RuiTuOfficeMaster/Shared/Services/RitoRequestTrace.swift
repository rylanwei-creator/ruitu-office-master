import Foundation

/// One bounded local diagnostic snapshot; never stores credentials, prompts or response content.
enum RitoRequestTrace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var values: [String:Any] = [:]
    nonisolated(unsafe) private static var lastWrite = Date.distantPast
    static var url: URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("RuiTuOfficeMaster/Diagnostics/last-ai-request.json")
    }
    static func begin(_ source: RitoReplySource) {
        guard ProcessInfo.processInfo.environment["RUITU_TEST_MODE"] != "1" else { return }
        lock.withLock { values = ["source":source.rawValue,"startedAt":Date().timeIntervalSince1970]; write() }
    }
    static func event(_ phase: String, count: Int? = nil, status: Int? = nil, flush: Bool = false) {
        guard ProcessInfo.processInfo.environment["RUITU_TEST_MODE"] != "1" else { return }
        lock.withLock {
            values["phase"] = phase; values["updatedAt"] = Date().timeIntervalSince1970
            if let count { values[phase] = (values[phase] as? Int ?? 0) + count }
            if let status { values["httpStatus"] = status }
            if flush || Date().timeIntervalSince(lastWrite) >= 1 { write() }
        }
    }
    static func failure(_ error: Error) {
        // Never persist localized server messages or any user/API content.
        let code: String
        if let e = error as? RitoCloudError { code = String(describing:e) }
        else if let e = error as? URLError { code = "url_" + String(e.errorCode) }
        else if let e = error as? RitoKeychainError { code = "keychain_" + String(e.status) }
        else { code = String(describing:type(of:error)) }
        event("reply_failed_" + code,flush:true)
    }
    private static func write() {
        do {
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:values,options:.sortedKeys).write(to:url,options:.atomic)
            lastWrite = Date()
        } catch { }
    }
}
