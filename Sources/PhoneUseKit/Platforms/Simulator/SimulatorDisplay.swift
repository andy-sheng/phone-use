import CoreGraphics
import Foundation
import IOSurface

/// The simulator's main framebuffer, shared with this process as an IOSurface.
///
/// A headless simulator may stop updating the surface while nobody observes it, so the session
/// keeps a damage registration for its whole lifetime. Until the first damage report arrives the
/// pixels may predate the registration; screenshots then use `simctl` instead.
///
/// CoreSimulator hands out remote proxies that marshal callback arguments according to the
/// block's type encoding, so the damage block must take an object (it receives an array of rects).
final class SimulatorDisplay: @unchecked Sendable {
    private static let bgra: OSType = 0x4247_5241 // 'BGRA'

    private let descriptor: AnyObject
    private let damageID = NSUUID()
    private let lock = NSLock()
    private var damageReports = 0
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var closed = false

    init(descriptor: AnyObject) {
        self.descriptor = descriptor
        let damaged: @convention(block) (AnyObject?) -> Void = { [weak self] _ in self?.damaged() }
        CoreSimulatorBridge.register(descriptor, "registerCallbackWithUUID:damageRectanglesCallback:",
                                     uuid: damageID, block: damaged as AnyObject)
    }

    deinit {
        close()
    }

    /// Read on each use (about 0.2 ms): the simulator may replace the surface, for example
    /// after a display resize, and its replacement notification has no stable signature.
    var currentSurface: IOSurface? {
        CoreSimulatorBridge.object(descriptor, "framebufferSurface") as? IOSurface
    }

    /// Whether the surface has been redrawn since this registration began.
    var isLive: Bool {
        lock.withLock { damageReports > 0 }
    }

    func pixelSize() throws -> (width: Int, height: Int) {
        guard let surface = currentSurface, surface.width > 0, surface.height > 0 else {
            throw DeviceHubError.serviceFailed("The simulator has no framebuffer; open it once in Simulator or reboot it")
        }
        return (surface.width, surface.height)
    }

    /// Runs `handler` on an arbitrary queue after each redraw.
    func addObserver(_ handler: @escaping @Sendable () -> Void) -> UUID {
        let token = UUID()
        lock.withLock { observers[token] = handler }
        return token
    }

    func removeObserver(_ token: UUID) {
        _ = lock.withLock { observers.removeValue(forKey: token) }
    }

    /// A copy of the current pixels, or nil when they may be stale or use an unexpected format.
    func liveImage() -> CGImage? {
        guard isLive, let surface = currentSurface, surface.pixelFormat == Self.bgra else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        surface.unlock(options: .readOnly, seed: nil)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: surface.bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    func close() {
        let wasOpen = lock.withLock {
            defer { closed = true; observers.removeAll() }
            return !closed
        }
        guard wasOpen else { return }
        CoreSimulatorBridge.invoke(descriptor, "unregisterDamageRectanglesCallbackWithUUID:", damageID)
    }

    private func damaged() {
        let handlers = lock.withLock {
            damageReports += 1
            return Array(observers.values)
        }
        for handler in handlers { handler() }
    }
}
