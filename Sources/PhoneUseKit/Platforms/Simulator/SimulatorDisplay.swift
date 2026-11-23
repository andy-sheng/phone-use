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

    struct Panel: @unchecked Sendable {
        let descriptor: AnyObject
        let identifier: String

        var digitizerTarget: UInt64 {
            guard let properties = CoreSimulatorBridge.object(descriptor, "screenProperties") else { return 0 }
            let selector = NSSelectorFromString("screenID")
            guard properties.responds(to: selector) else { return 0 }
            typealias ID = @convention(c) (AnyObject, Selector) -> UInt32
            return UInt64(unsafeBitCast(properties.method(for: selector), to: ID.self)(properties, selector))
        }

        /// simctl applies the guest interface orientation to its PNG. The raw IOSurface does not.
        var screenshotOrientation: DeviceOrientation {
            let selector = NSSelectorFromString("uiOrientation")
            guard let properties = CoreSimulatorBridge.object(descriptor, "screenProperties"),
                  properties.responds(to: selector) else { return .portrait }
            typealias Read = @convention(c) (AnyObject, Selector) -> UInt32
            switch unsafeBitCast(properties.method(for: selector), to: Read.self)(properties, selector) {
            case 2: return .portraitUpsideDown
            case 3: return .landscapeRight
            case 4: return .landscapeLeft
            default: return .portrait
            }
        }

        var area: Int {
            guard let surface = CoreSimulatorBridge.object(descriptor, "framebufferSurface") as? IOSurface else { return 0 }
            return surface.width * surface.height
        }

        var isLit: Bool {
            guard let properties = CoreSimulatorBridge.object(descriptor, "screenProperties"),
                  let backlight = CoreSimulatorBridge.object(properties, "backlight") else { return false }
            let selector = NSSelectorFromString("state")
            guard backlight.responds(to: selector) else { return false }
            typealias State = @convention(c) (AnyObject, Selector) -> Int32
            return unsafeBitCast(backlight.method(for: selector), to: State.self)(backlight, selector) > 0
        }
    }

    private let panels: [Panel]
    private let landscapePanelIdentifier: String?
    private var selectedIndex = 0
    private var commandedIndex: Int?
    private var currentOrientation = DeviceOrientation.portrait
    var orientation: DeviceOrientation { lock.withLock { currentOrientation } }
    /// Duo's inner panel is mounted a quarter-turn from the cover, despite both IOSurfaces
    /// reporting portrait dimensions. Keep the physical sensor pose separate from this correction.
    var framebufferOrientation: DeviceOrientation {
        let physical = orientation
        return selectedPanel.identifier == landscapePanelIdentifier ? physical.rotated(.right) : physical
    }

    var simctlScreenshotCorrection: DeviceOrientation {
        let turns = framebufferOrientation.quarterTurns - selectedPanel.screenshotOrientation.quarterTurns
        return DeviceOrientation.allCases[(turns + 4) % 4]
    }

    func setOrientation(_ orientation: DeviceOrientation) {
        let handlers = lock.withLock {
            currentOrientation = orientation
            return closed ? [] : Array(observers.values)
        }
        for handler in handlers { handler() }
    }
    var isFoldable: Bool { panels.count == 2 }

    /// Port powerState stays on for both Duo screens. The screen backlight identifies the active one.
    private var selectedPanel: Panel {
        if panels.count == 1 { return panels[0] }
        if let index = lock.withLock({ commandedIndex }) { return panels[index] }
        let lit = panels.firstIndex(where: { $0.isLit })
        return lock.withLock {
            if let lit { selectedIndex = lit }
            return panels[selectedIndex]
        }
    }

    var identifier: String { selectedPanel.identifier }
    var digitizerTarget: UInt64 { isFoldable ? selectedPanel.digitizerTarget : 0 }

    func select(_ posture: SimulatorPosture) {
        guard isFoldable else { return }
        let ordered = panels.indices.sorted { panels[$0].area < panels[$1].area }
        // This runtime can report the cover backlight as on after moving the scene inside.
        // Like DeviceHub, prefer the commanded hinge's panel over inconsistent backlight metadata.
        lock.withLock {
            commandedIndex = posture == .closed ? ordered.first : ordered.last
            selectedIndex = commandedIndex ?? selectedIndex
        }
        let handlers = lock.withLock { closed ? [] : Array(observers.values) }
        for handler in handlers { handler() }
    }
    private let damageID = NSUUID()
    private let lock = NSLock()
    private var damageReports: Set<String> = []
    private var observers: [UUID: @Sendable () -> Void] = [:]
    private var closed = false

    init(panels: [Panel]) {
        precondition(!panels.isEmpty)
        self.panels = panels
        landscapePanelIdentifier = panels.count == 2 ? panels.max(by: { $0.area < $1.area })?.identifier : nil
        for panel in panels {
            let identifier = panel.identifier
            let damaged: @convention(block) (AnyObject?) -> Void = { [weak self] _ in self?.damaged(identifier) }
            CoreSimulatorBridge.register(panel.descriptor, "registerCallbackWithUUID:damageRectanglesCallback:",
                                         uuid: damageID, block: damaged as AnyObject)
        }
    }

    deinit {
        close()
    }

    /// Read on each use (about 0.2 ms): the simulator may replace the surface, for example
    /// after a display resize, and its replacement notification has no stable signature.
    var currentSurface: IOSurface? {
        CoreSimulatorBridge.object(selectedPanel.descriptor, "framebufferSurface") as? IOSurface
    }

    /// Whether the surface has been redrawn since this registration began.
    var isLive: Bool {
        let identifier = identifier
        return lock.withLock { damageReports.contains(identifier) }
    }

    func pixelSize() throws -> (width: Int, height: Int) {
        guard let surface = currentSurface, surface.width > 0, surface.height > 0 else {
            throw DeviceHubError.serviceFailed("The simulator has no framebuffer; open it once in Simulator or reboot it")
        }
        return framebufferOrientation.isLandscape ? (surface.height, surface.width) : (surface.width, surface.height)
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
        guard let image = CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: surface.bytesPerRow, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return try? framebufferOrientation.image(image)
    }

    func close() {
        let wasOpen = lock.withLock {
            defer { closed = true; observers.removeAll() }
            return !closed
        }
        guard wasOpen else { return }
        for panel in panels {
            CoreSimulatorBridge.invoke(panel.descriptor, "unregisterDamageRectanglesCallbackWithUUID:", damageID)
        }
    }

    private func damaged(_ identifier: String) {
        let handlers = lock.withLock {
            guard !closed else { return [@Sendable () -> Void]() }
            damageReports.insert(identifier)
            return Array(observers.values)
        }
        for handler in handlers { handler() }
    }
}
