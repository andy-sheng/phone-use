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
    @Published private(set) var isAndroid = false
    @Published private(set) var streamError: String?
    @Published private(set) var fallbackMessage: String?
    @Published private(set) var requestedDeviceID: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var connectionError: String?
    @Published private(set) var isReconnecting = false
    @Published private(set) var reconnectGeneration = 0
    /// A short confirmation or error shown over the screen, cleared after a few seconds.
    @Published private(set) var notice: String?

    private var session: DeviceSession?
    private var noticeTask: Task<Void, Never>?
    private var currentDeviceID: String?
    private var manualTouch: (session: DeviceSession, point: CGPoint)?
    private var runGeneration = UUID()
    private let prepareSession: @MainActor (DeviceSummary) async -> Void
    private let openSession: @MainActor (String) async throws -> DeviceSession
    private let connectionAttempts: Int
    private let retryDelay: Duration

    init(prepareSession: @escaping @MainActor (DeviceSummary) async -> Void = { await prepareScreenSession(for: $0) },
         openSession: @escaping @MainActor (String) async throws -> DeviceSession = { try await DeviceHub.shared.session(for: $0) },
         connectionAttempts: Int = 5, retryDelay: Duration = .seconds(2)) {
        self.prepareSession = prepareSession
        self.openSession = openSession
        self.connectionAttempts = max(connectionAttempts, 1)
        self.retryDelay = retryDelay
    }

    /// Discovery and selection alone never prepare USB capture or open a device session.
    func requestConnection(to device: DeviceSummary) {
        guard device.isReady else { return }
        if requestedDeviceID == device.id && (isConnecting || stream != nil) { return }
        requestedDeviceID = device.id
        reconnectGeneration += 1
    }

    func selectionChanged(to deviceID: String?) {
        if requestedDeviceID != deviceID { requestedDeviceID = nil }
    }

    func cancelConnection() {
        requestedDeviceID = nil
        reconnectGeneration += 1
    }

    func isShowingDevice(_ deviceID: String) -> Bool {
        currentDeviceID == deviceID
    }

    private func isCurrentRequest(_ deviceID: String, generation: UUID) -> Bool {
        runGeneration == generation && requestedDeviceID == deviceID && !Task.isCancelled
    }

    /// Runs only an explicitly requested preview, for the lifetime of the surrounding view task.
    func run(device: DeviceSummary?) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        runGeneration = generation
        releaseManualTouch()
        stream?.stop()
        stream = nil
        session = nil
        display = nil
        framesPerSecond = nil
        isAndroid = device?.isAndroid ?? false
        currentDeviceID = device?.id
        aspectRatio = device?.isPad == true ? 3.0 / 4.0 : 393.0 / 852.0
        isConnecting = false
        connectionError = nil
        status = nil
        streamError = nil
        fallbackMessage = nil
        noticeTask?.cancel()
        notice = nil
        guard let device, device.isReady, requestedDeviceID == device.id else { return }
        isConnecting = true
        defer {
            if runGeneration == generation { isConnecting = false }
        }
        status = "Connecting to \(device.name)…"
        await prepareSession(device)
        guard isCurrentRequest(device.id, generation: generation) else { return }
        var opened: DeviceSession?
        var lastError: String?
        for attempt in 1...connectionAttempts {
            guard isCurrentRequest(device.id, generation: generation) else { return }
            do {
                opened = try await openSession(device.udid)
                break
            } catch {
                guard isCurrentRequest(device.id, generation: generation) else { return }
                lastError = String(describing: error)
                if attempt < connectionAttempts {
                    status = "Waiting for \(device.name)…"
                    do { try await Task.sleep(for: retryDelay) }
                    catch { return }
                }
            }
        }
        guard isCurrentRequest(device.id, generation: generation) else { return }
        guard let session = opened else {
            connectionError = lastError ?? "Unable to connect to \(device.name)."
            status = nil
            return
        }
        self.session = session
        session.onTouchError = { [weak self, weak session] message in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.show(message)
            }
        }
        display = session.display
        aspectRatio = session.display.pixelWidth / session.display.pixelHeight
        status = "Starting screen…"

        var stream = await makeScreenStream(for: session)
        guard isCurrentRequest(device.id, generation: generation) else { stream.stop(); return }
        attach(stream)
        status = nil
        isConnecting = false

        // A video source can come up late, for example after the device re-enumerates on USB,
        // so screenshot polling keeps retrying until one is available.
        while isCurrentRequest(device.id, generation: generation) {
            try? await Task.sleep(for: .seconds(stream.kind == .screenshots ? 5 : 1))
            guard stream.recoveryPolicy == .retryVideo, isCurrentRequest(device.id, generation: generation),
                  let video = await makeVideoScreenStream(for: session) else { continue }
            guard isCurrentRequest(device.id, generation: generation) else {
                video.stop()
                break
            }
            stream.stop()
            stream = video
            attach(video)
        }
        stream.stop()
        if self.stream === stream {
            self.stream = nil
        }
    }

    private func attach(_ stream: any ScreenStream) {
        // Error callbacks may replay a failure that happened just after startup.
        self.stream = stream
        framesPerSecond = nil
        streamError = nil
        fallbackMessage = stream.statusMessage
        stream.onFrame = { [weak self, weak stream] fps in
            guard let self, let stream, self.stream === stream else { return }
            self.framesPerSecond = fps
            self.streamError = nil
        }
        stream.onError = { [weak self, weak stream] message in
            guard let self, let stream, self.stream === stream, self.streamError != message else { return }
            self.streamError = message
            self.framesPerSecond = nil
            self.show(message)
        }
    }

    /// A deliberate reset is required after Android changes display geometry. The view disables
    /// this action while automation owns this device, so an active gesture is never interrupted.
    func reconnect() async {
        guard isAndroid, let session, !isReconnecting else { return }
        let deviceID = session.device.id
        isReconnecting = true
        defer { isReconnecting = false }
        stream?.stop()
        do {
            try await DeviceHub.shared.resetSession(for: deviceID)
            guard currentDeviceID == deviceID else { return }
            reconnectGeneration += 1
        } catch {
            guard currentDeviceID == deviceID else { return }
            streamError = String(describing: error)
            show(String(describing: error))
        }
    }

    func touch(_ phase: TouchPhase, at point: CGPoint) {
        let point = clamped(point)
        switch phase {
        case .began:
            releaseManualTouch()
            guard let session else { return }
            manualTouch = (session, point)
            session.touch(.began, x: point.x, y: point.y)
        case .moved:
            guard let held = manualTouch else { return }
            manualTouch = (held.session, point)
            held.session.touch(.moved, x: point.x, y: point.y)
        case .ended:
            guard let held = manualTouch else { return }
            manualTouch = nil
            held.session.touch(.ended, x: point.x, y: point.y)
        }
    }

    private func releaseManualTouch() {
        guard let held = manualTouch else { return }
        manualTouch = nil
        // Keep this release behind the manual gesture's queued events on its original session.
        held.session.touch(.ended, x: held.point.x, y: held.point.y)
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }

    func flick(from start: CGPoint, by delta: CGVector) {
        guard let session else { return }
        let end = clamped(CGPoint(x: start.x + delta.dx, y: start.y + delta.dy))
        let start = clamped(start)
        Task {
            do {
                try await session.swipe(fromX: start.x, fromY: start.y,
                                        toX: end.x, toY: end.y,
                                        duration: .milliseconds(80))
            } catch {
                guard self.session === session else { return }
                show("\(error)")
            }
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
