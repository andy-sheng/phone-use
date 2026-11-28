import Foundation

struct QueuedTouch: Sendable {
    let phase: TouchPhase
    let x: Double
    let y: Double
}

/// Used by one queue consumer. A failed Android gesture keeps its first useful error while
/// still attempting release; the next begin starts a fresh attempt.
struct QueuedTouchDelivery: Sendable {
    let suppressFailedGestures: Bool
    let send: @Sendable (QueuedTouch) async throws -> Void
    let reportError: @Sendable (String) -> Void
    private var gestureFailed = false

    init(suppressFailedGestures: Bool,
         send: @escaping @Sendable (QueuedTouch) async throws -> Void,
         reportError: @escaping @Sendable (String) -> Void) {
        self.suppressFailedGestures = suppressFailedGestures
        self.send = send
        self.reportError = reportError
    }

    mutating func deliver(_ event: QueuedTouch) async {
        if suppressFailedGestures {
            if event.phase == .began { gestureFailed = false }
            if event.phase == .moved && gestureFailed { return }
        }
        do {
            try await send(event)
        } catch {
            if !suppressFailedGestures || !gestureFailed {
                reportError(String(describing: error))
            }
            gestureFailed = true
        }
        if event.phase == .ended { gestureFailed = false }
    }
}

/// A cached session can rebind its preview without racing an in-flight touch failure.
final class TouchErrorHandlerBox: @unchecked Sendable {
    typealias Handler = @Sendable (String) -> Void
    private let lock = NSLock()
    private var storedHandler: Handler?

    var handler: Handler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }

    func report(_ message: String) {
        let callback = handler
        callback?(message)
    }
}

/// Keeps touch boundaries while replacing only adjacent, still-pending move events.
/// A separate wake stream may coalesce notifications without dropping actual events.
final class TouchEventQueue: @unchecked Sendable {
    enum Event {
        case touch(QueuedTouch)
        case keyboard([DeviceKeystroke])
    }

    let notifications: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private let coalesceMoves: Bool
    private var events: [Event] = []
    private var finished = false

    init(coalesceMoves: Bool) {
        self.coalesceMoves = coalesceMoves
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        notifications = stream
        self.continuation = continuation
    }

    func enqueue(_ phase: TouchPhase, x: Double, y: Double) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        let event = QueuedTouch(phase: phase, x: x, y: y)
        if coalesceMoves, phase == .moved, case .touch(let last) = events.last, last.phase == .moved {
            events[events.count - 1] = .touch(event)
        } else {
            events.append(.touch(event))
        }
        lock.unlock()
        continuation.yield(())
    }

    func enqueue(_ key: DeviceKeystroke) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        // Batch adjacent keystrokes while the device is busy, without crossing a touch.
        if case .keyboard(var keys) = events.last, keys.count < 32 {
            keys.append(key)
            events[events.count - 1] = .keyboard(keys)
        } else {
            events.append(.keyboard([key]))
        }
        lock.unlock()
        continuation.yield(())
    }

    func discardKeystrokes() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll { event in
            if case .keyboard = event { return true }
            return false
        }
    }

    func next() -> Event? {
        lock.lock()
        defer { lock.unlock() }
        return events.isEmpty ? nil : events.removeFirst()
    }

    func finish() {
        lock.lock()
        finished = true
        events.removeAll()
        lock.unlock()
        continuation.finish()
    }
}
