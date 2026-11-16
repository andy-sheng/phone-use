import Foundation

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T) {
        self.value = value
    }
}

/// Frames per second over one-second windows.
struct FrameMeter {
    private var windowStart = Date()
    private var frames = 0

    mutating func tick() -> Double? {
        frames += 1
        let elapsed = Date().timeIntervalSince(windowStart)
        guard elapsed >= 1 else { return nil }
        defer {
            frames = 0
            windowStart = Date()
        }
        return Double(frames) / elapsed
    }
}
