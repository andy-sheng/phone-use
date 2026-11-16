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
    let notifications: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private let coalesceMoves: Bool
    private var events: [QueuedTouch] = []
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
        if coalesceMoves, phase == .moved, events.last?.phase == .moved {
            events[events.count - 1] = event
        } else {
            events.append(event)
        }
        lock.unlock()
        continuation.yield(())
    }

    func next() -> QueuedTouch? {
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
