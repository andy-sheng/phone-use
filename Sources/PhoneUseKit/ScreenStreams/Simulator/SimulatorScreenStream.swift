import CoreGraphics
import Foundation
import QuartzCore

/// Shows the simulator's framebuffer IOSurface directly; each damage report refreshes the layer.
@MainActor
final class SimulatorScreenStream: ScreenStream {
    typealias Snapshot = @Sendable () async throws -> CGImage

    let kind = ScreenStreamKind.simulator
    let layer = CALayer()
    var onFrame: ((Double) -> Void)?
    var onError: ((String) -> Void)?

    private let display: SimulatorDisplay
    private let snapshot: Snapshot
    private var observer: UUID?
    private var snapshotTask: Task<Void, Never>?
    private let gate = FrameGate()
    private var lastFrame: Date?
    private var fps = 0.0

    init(display: SimulatorDisplay, snapshot: @escaping Snapshot) {
        self.display = display
        self.snapshot = snapshot
        layer.contentsGravity = .resize
    }

    func start() async throws {
        stop()
        guard let surface = display.currentSurface else {
            throw DeviceHubError.serviceFailed("The simulator has no framebuffer")
        }
        let gate = gate
        observer = display.addObserver { [weak self] in
            // Coalesce bursts of damage into one main-actor refresh.
            guard gate.claim() else { return }
            Task { @MainActor in self?.refresh() }
        }
        if display.isLive {
            show(surface)
        } else {
            // Until the simulator redraws, its surface may still show an earlier screen.
            let snapshot = snapshot
            snapshotTask = Task { [weak self] in
                guard let image = try? await snapshot(), let self, !Task.isCancelled, !self.display.isLive else { return }
                self.setContents(image)
            }
        }
    }

    func stop() {
        if let observer { display.removeObserver(observer) }
        observer = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        lastFrame = nil
        fps = 0
    }

    private func refresh() {
        gate.reset()
        guard observer != nil, let surface = display.currentSurface else { return }
        snapshotTask?.cancel()
        show(surface)
        let now = Date()
        if let lastFrame {
            let current = 1 / max(now.timeIntervalSince(lastFrame), 0.001)
            fps = fps == 0 ? current : fps * 0.8 + current * 0.2
            onFrame?(fps)
        }
        lastFrame = now
    }

    private func show(_ surface: IOSurface) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if (layer.contents as AnyObject?) !== surface {
            layer.contents = surface
        } else if layer.responds(to: Self.contentsChanged) {
            // The surface is reused for every frame; tell Core Animation its pixels changed.
            layer.perform(Self.contentsChanged)
        } else {
            layer.contents = nil
            layer.contents = surface
        }
        CATransaction.commit()
    }

    private func setContents(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = image
        CATransaction.commit()
    }

    private static let contentsChanged = NSSelectorFromString("setContentsChanged")
}

/// At most one refresh waits for the main actor; damage reports arrive on CoreSimulator's queues.
private final class FrameGate: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false

    func claim() -> Bool {
        lock.withLock {
            defer { pending = true }
            return !pending
        }
    }

    func reset() {
        lock.withLock { pending = false }
    }
}

@MainActor
enum SimulatorScreenStreamProvider {
    static func makeStream(_ session: DeviceSession) async -> any ScreenStream {
        if let video = await makeVideo(session) { return video }
        let message = "Simulator display unavailable. Using screenshot preview."
        let fallback = ScreenshotScreenStream(session: session, recoveryPolicy: .retryVideo,
                                              statusMessage: message, stopOnError: false)
        if !Task.isCancelled { try? await fallback.start() }
        return fallback
    }

    static func makeVideo(_ session: DeviceSession) async -> (any ScreenStream)? {
        guard let display = session.simulatorDisplay else { return nil }
        let stream = SimulatorScreenStream(display: display) { try await session.screenshot() }
        do {
            try await stream.start()
            return stream
        } catch {
            stream.stop()
            FileHandle.standardError.write(Data("Simulator display unavailable: \(error)\n".utf8))
            return nil
        }
    }
}
