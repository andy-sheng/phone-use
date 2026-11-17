import Foundation

/// Waits for actual process termination, even when the awaiting task is cancelled.
/// Pipe EOF and cancellation of an AsyncStream are not evidence that a process exited.
final class ProcessTermination: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    /// Install before launching the process; owns its termination handler.
    init(_ process: Process) {
        process.terminationHandler = { [self] process in
            complete(process.terminationStatus)
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    private func complete(_ status: Int32) {
        lock.lock()
        self.status = status
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume(returning: status) }
    }
}
