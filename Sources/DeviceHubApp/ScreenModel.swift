import CoreGraphics
import DeviceHubKit
import Foundation

@MainActor
final class ScreenModel: ObservableObject {
    @Published private(set) var stream: (any ScreenStream)?
    @Published private(set) var aspectRatio: CGFloat = 393.0 / 852.0
    @Published private(set) var framesPerSecond: Double?
    @Published private(set) var status: String?
    @Published private(set) var display: DisplayInfo?
    /// A short confirmation or error shown over the screen, cleared after a few seconds.
    @Published private(set) var notice: String?

    private var session: DeviceSession?
    private var noticeTask: Task<Void, Never>?

    /// Connects to the device and keeps its screen stream alive until the surrounding task is cancelled.
    func run(device: DeviceSummary) async {
        stream = nil
        session = nil
        display = nil
        framesPerSecond = nil
        guard device.isReady else {
            status = nil
            return
        }
        status = "Connecting to \(device.name)…"
        if device.isWired {
            await USBScreenCapture.waitUntilSettled()
        }
        // A cached session may point at a tunnel that has since been rebuilt, so every start opens a fresh one.
        await DeviceHub.shared.closeSession(for: device.udid)
        var opened: DeviceSession?
        for attempt in 1...5 {
            do {
                opened = try await DeviceHub.shared.session(for: device.udid)
                break
            } catch {
                status = attempt == 5 ? "\(error)" : "Waiting for \(device.name)…"
                try? await Task.sleep(for: .seconds(2))
            }
        }
        guard let session = opened, !Task.isCancelled else { return }
        self.session = session
        display = session.display
        aspectRatio = session.display.pixelWidth / session.display.pixelHeight
        status = "Starting screen…"

        let stream = await makeScreenStream(for: session)
        stream.onFrame = { [weak self] fps in self?.framesPerSecond = fps }
        self.stream = stream
        status = nil

        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
        }
        stream.stop()
        if self.stream === stream {
            self.stream = nil
        }
    }

    func touch(_ phase: TouchPhase, at point: CGPoint) {
        session?.touch(phase, x: point.x, y: point.y)
    }

    func flick(from start: CGPoint, by delta: CGVector) {
        guard let session else { return }
        Task {
            try? await session.swipe(fromX: start.x, fromY: start.y,
                                     toX: start.x + delta.dx, toY: start.y + delta.dy,
                                     duration: .milliseconds(80))
        }
    }

    func press(_ button: HardwareButton) {
        guard let session else { return }
        Task {
            do {
                try await session.press(button)
            } catch {
                show("\(error)")
            }
        }
    }

    /// Saves a full-resolution PNG to the Desktop.
    func saveScreenshot() {
        guard let session else { return }
        Task {
            do {
                let image = try await session.screenshot()
                guard let png = ImageEncoding.png(image) else { throw DeviceHubError.serviceFailed("PNG encoding failed") }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                let name = "\(session.device.name) \(formatter.string(from: Date())).png"
                let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
                try png.write(to: url)
                show("Saved \(name) to the Desktop")
            } catch {
                show("\(error)")
            }
        }
    }

    func launchApp(bundleID: String) {
        guard let session, !bundleID.isEmpty else { return }
        Task {
            do {
                try await session.launchApp(bundleID: bundleID)
                show("Launched \(bundleID)")
            } catch {
                show("\(error)")
            }
        }
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { notice = nil }
        }
    }
}
