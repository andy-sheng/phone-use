import CoreGraphics
import Foundation

/// The platform boundary for device control. Coordinates remain normalized at this boundary;
/// Apple service messages and Android RPC details belong to their respective adapters.
protocol DeviceConnection: Sendable {
    var touchPolicy: TouchQueuePolicy { get }
    func sendTouch(_ phase: TouchPhase, x: Double, y: Double) async throws
    func tap(x: Double, y: Double) async throws
    func longPress(x: Double, y: Double, duration: Duration) async throws
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Duration) async throws
    func press(_ button: HardwareButton, duration: Duration?) async throws
    func screenshot() async throws -> CGImage
    func launchApp(bundleID: String) async throws
    func uiTree() async throws -> UITree
    func activate(_ selector: UISelector) async throws
    func typeText(_ text: String, target: UISelector?) async throws
    func close() async
}

extension DeviceConnection {
    func uiTree() async throws -> UITree { throw DeviceHubError.capabilityUnavailable("UI tree on this device; supported on iOS (physical UI trees require development signing). Use screenshot for this device") }
    func activate(_ selector: UISelector) async throws { throw DeviceHubError.capabilityUnavailable("Element targeting on this device; supported on iOS (physical UI trees require development signing). Use screenshot and coordinate tap") }
    func typeText(_ text: String, target: UISelector?) async throws { throw DeviceHubError.capabilityUnavailable("Direct text input on this device; supported on iOS (physical UI trees require development signing). Use the on-screen keyboard") }
}

/// How `DeviceSession` delivers the interactive preview's queued touches to one adapter.
struct TouchQueuePolicy: Sendable {
    /// Replace an adjacent, still-pending move with the newest one.
    var coalescesMoves: Bool
    /// After a gesture's begin or move fails, skip its remaining moves and report only the first error.
    var suppressesFailedGestures: Bool
    /// Drop pending events on close. The adapter's `close` must then release a held contact itself.
    var dropsPendingOnClose: Bool
}

extension Duration {
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
