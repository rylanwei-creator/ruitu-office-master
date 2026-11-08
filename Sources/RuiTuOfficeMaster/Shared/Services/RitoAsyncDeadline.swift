import Foundation

/// Returns at the deadline even if a system authorization call ignores cancellation.
/// Late work remains cancelled and cannot publish a second result.
enum RitoAsyncDeadline {
    static func run<Value: Sendable>(seconds: TimeInterval, timeout: any Error = RitoCloudError.timeout,
                                    operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let race = RitoDeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard race.install(continuation) else { return }
                let worker = Task {
                    do { race.finish(.success(try await operation())) }
                    catch { race.finish(.failure(error)) }
                }
                race.attach(worker)
                let timer = Task {
                    do { try await Task.sleep(for:.seconds(seconds)); race.finish(.failure(timeout)) }
                    catch { }
                }
                race.attach(timer)
            }
        } onCancel: { race.finish(.failure(CancellationError())) }
    }
}

private final class RitoDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var tasks: [Task<Void,Never>] = []
    func install(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with:result); return false }
        self.continuation = continuation; lock.unlock(); return true
    }
    func attach(_ task: Task<Void,Never>) {
        lock.lock()
        if result != nil { lock.unlock(); task.cancel(); return }
        tasks.append(task); lock.unlock()
    }
    func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation, tasks = self.tasks
        self.continuation = nil; self.tasks = []; lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with:result)
    }
}
