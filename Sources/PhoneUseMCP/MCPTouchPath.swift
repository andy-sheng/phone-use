import Foundation
import PhoneUseKit

extension MCPDeviceSession {
    /// Receives an entirely validated, normalized polyline. Interpolate each segment while
    /// keeping one contact down, including across repeated points used as holds.
    func trace(_ points: [CGPoint], duration: Duration) async throws {
        guard let first = points.first, points.count >= 2 else { throw ToolFailure(message: "A touch path needs two points.") }
        let segment = duration / (points.count - 1)
        let steps = max(1, Int(ceil((segment / .seconds(1)) * 60)))
        var last = first
        try Task.checkCancellation()
        do {
            try await sendTouch(.began, x: first.x, y: first.y)
            let start = ContinuousClock.now
            for index in 1..<points.count {
                let from = points[index - 1], to = points[index]
                for step in 1...steps {
                    try await Task.sleep(until: start + segment * (index - 1) + segment * step / steps, clock: .continuous)
                    let fraction = Double(step) / Double(steps)
                    let next = CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
                    try await sendTouch(.moved, x: next.x, y: next.y)
                    last = next
                }
            }
            try await sendTouch(.ended, x: last.x, y: last.y)
        } catch {
            // The down event may have reached the device even when its acknowledgement failed.
            // Release from an uncancelled task before letting another gesture acquire the device.
            let position = last
            try? await Task { try await self.sendTouch(.ended, x: position.x, y: position.y) }.value
            throw error
        }
    }
}

/// Long gestures, lifecycle and geometry changes must not interleave with other MCP input.
/// Ordinary calls on a device retain their previous concurrency when no exclusive call is active.
final class MCPDeviceOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [String: Int] = [:]
    private var exclusive: Set<String> = []

    func enter(_ device: String, exclusive needsExclusive: Bool) throws {
        try lock.withLock {
            guard !exclusive.contains(device), !needsExclusive || active[device] == nil else {
                throw ToolFailure(message: "Another device operation is in progress. Retry after it finishes.")
            }
            active[device, default: 0] += 1
            if needsExclusive { exclusive.insert(device) }
        }
    }

    func leave(_ device: String) {
        lock.withLock {
            exclusive.remove(device)
            if active[device] == 1 { active[device] = nil } else { active[device]? -= 1 }
        }
    }
}
