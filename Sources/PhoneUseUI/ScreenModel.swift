import CoreGraphics
import PhoneUseKit
import Foundation

@MainActor
public final class ScreenModel: ObservableObject {
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
    /// Whether the preview stream or simulator recording backend can save video.
    @Published private(set) var canRecord = false
    @Published private(set) var isRecording = false
    @Published private(set) var canFold = false
    @Published private(set) var canRotate = false
    @Published private(set) var isChangingGeometry = false
    @Published private(set) var posture: SimulatorPosture?

    private var session: DeviceSession?
    private var settings: DeviceSettings?
    private var recording: (any ScreenRecordingSession)?
    private var noticeTask: Task<Void, Never>?
    private var currentDeviceID: String?
    private var requestedSimulatorStartID: String?
    private var manualTouch: (session: DeviceSession, point: CGPoint)?
    private var runGeneration = UUID()
    private let prepareSession: @MainActor (DeviceSummary) async -> Void
    private let openSession: @MainActor (String) async throws -> DeviceSession
    private let startSimulator: @MainActor (DeviceSummary) async throws -> Void
    private let connectionAttempts: Int
    private let retryDelay: Duration

    init(prepareSession: @escaping @MainActor (DeviceSummary) async -> Void = { await prepareScreenSession(for: $0) },
         openSession: @escaping @MainActor (String) async throws -> DeviceSession = { try await DeviceHub.shared.session(for: $0) },
         startSimulator: @escaping @MainActor (DeviceSummary) async throws -> Void = {
             await DeviceHub.shared.closeSession(for: $0.id)
             try await SimulatorLifecycle.start($0)
         },
         connectionAttempts: Int = 5, retryDelay: Duration = .seconds(2)) {
        self.prepareSession = prepareSession
        self.openSession = openSession
        self.startSimulator = startSimulator
        self.connectionAttempts = max(connectionAttempts, 1)
        self.retryDelay = retryDelay
    }

    /// Discovery and selection alone never prepare USB capture or open a device session.
    func requestConnection(to device: DeviceSummary) {
        guard device.isReady || device.canStartSimulator else { return }
        if requestedDeviceID == device.id && (isConnecting || stream != nil) { return }
        requestedDeviceID = device.id
        requestedSimulatorStartID = device.canStartSimulator ? device.id : nil
        reconnectGeneration += 1
    }

    func selectionChanged(to deviceID: String?) {
        if requestedDeviceID != deviceID {
            requestedDeviceID = nil
            requestedSimulatorStartID = nil
        }
    }

    func cancelConnection() {
        requestedDeviceID = nil
        requestedSimulatorStartID = nil
        reconnectGeneration += 1
    }

    func isShowingDevice(_ deviceID: String) -> Bool {
        currentDeviceID == deviceID
    }

    /// Read through the preview's existing shared session; selecting a device alone never opens one.
    func uiTree(for deviceID: String) async throws -> UITree? {
        guard currentDeviceID == deviceID, let session, session.device.id == deviceID else { return nil }
        let tree = try await session.uiTree()
        guard currentDeviceID == deviceID, self.session === session else { return nil }
        return tree
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
        finishRecording()
        settings = nil
        canRecord = false
        stream?.stop()
        stream = nil
        session = nil
        display = nil
        canFold = false
        canRotate = false
        posture = nil
        isChangingGeometry = false
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
        guard let device, device.isReady || device.canStartSimulator, requestedDeviceID == device.id else { return }
        // Shutting down a live preview must not turn the simulator back on automatically.
        guard device.isReady || requestedSimulatorStartID == device.id else { return }
        if device.isReady { requestedSimulatorStartID = nil }
        isConnecting = true
        defer {
            if runGeneration == generation { isConnecting = false }
        }
        if device.canStartSimulator {
            status = "Starting \(device.name)…"
            do {
                try await startSimulator(device)
            } catch {
                guard isCurrentRequest(device.id, generation: generation) else { return }
                connectionError = String(describing: error)
                status = nil
                return
            }
            guard isCurrentRequest(device.id, generation: generation) else { return }
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
                let code: String? = if case DeviceHubError.daemon(let code, _) = error { code } else { nil }
                Diagnostics.record("preview.connect.failed", ["device": Diagnostics.deviceID(device.udid), "attempt": String(attempt),
                                                              "code": code ?? "", "error": String(describing: error)])
                lastError = String(describing: error)
                // The device answered and refused the pairing; asking again gets the same answer.
                if code == "wirelessPairingRejected" { break }
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
        updateDisplay(session)
        canFold = session.canFold
        canRotate = session.canRotate
        status = "Starting screen…"

        var stream = await makeScreenStream(for: session)
        guard isCurrentRequest(device.id, generation: generation) else { stream.stop(); return }
        attach(stream)
        status = nil
        isConnecting = false
        Task {
            let settings = await DeviceSettings.resolve(for: device)
            guard isCurrentRequest(device.id, generation: generation) else { return }
            self.settings = settings
            canRecord = self.stream?.canRecord == true || settings?.canRecord == true
        }

        // A video source can come up late, for example after the device re-enumerates on USB,
        // so screenshot polling keeps retrying until one is available.
        while isCurrentRequest(device.id, generation: generation) {
            try? await Task.sleep(for: .seconds(stream.kind == .screenshots ? 5 : 1))
            guard isCurrentRequest(device.id, generation: generation) else { break }
            updateDisplay(session)
            if let recording, !recording.isRunning { finishRecording() }
            guard stream.recoveryPolicy == .retryVideo, isCurrentRequest(device.id, generation: generation),
                  let video = await makeVideoScreenStream(for: session) else { continue }
            guard isCurrentRequest(device.id, generation: generation) else {
                video.stop()
                break
            }
            finishRecording()
            stream.stop()
            stream = video
            attach(video)
        }
        if self.stream === stream { finishRecording() }
        stream.stop()
        if self.stream === stream {
            self.stream = nil
        }
    }

    private func attach(_ stream: any ScreenStream) {
        Diagnostics.record("preview.stream", ["kind": String(describing: stream.kind), "fallback": stream.statusMessage ?? ""])
        // Error callbacks may replay a failure that happened just after startup.
        self.stream = stream
        canRecord = stream.canRecord || settings?.canRecord == true
        framesPerSecond = nil
        streamError = nil
        fallbackMessage = stream.statusMessage
        stream.onFrame = { [weak self, weak stream] fps in
            guard let self, let stream, self.stream === stream else { return }
            // Streams report every frame; publish only what the UI shows, so the window is not
            // re-rendered for each frame.
            let shown = fps.rounded()
            if self.framesPerSecond != shown { self.framesPerSecond = shown }
            if let session = self.session { self.updateDisplay(session) }
            if self.streamError != nil { self.streamError = nil }
        }
        stream.onError = { [weak self, weak stream] message in
            guard let self, let stream, self.stream === stream, self.streamError != message else { return }
            Diagnostics.record("preview.stream.failed", ["error": message])
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

    private func updateDisplay(_ session: DeviceSession) {
        let next = session.display
        if display?.pixelWidth != next.pixelWidth || display?.pixelHeight != next.pixelHeight {
            display = next
            aspectRatio = next.pixelWidth / next.pixelHeight
        }
    }

    func endPreview() async {
        let saving = finishRecording()
        cancelConnection()
        await saving?.value
    }

    func setPosture(_ posture: SimulatorPosture) { requestGeometry(.posture(posture)) }

    func rotate(_ direction: DeviceRotationDirection) { requestGeometry(.rotation(direction)) }

    private func requestGeometry(_ change: SimulatorGeometryChange) {
        let generation = runGeneration
        Task {
            guard generation == runGeneration else { return }
            do { try await changeGeometry(change) }
            catch { if generation == runGeneration { show(String(describing: error)) } }
        }
    }

    func changeGeometry(_ change: SimulatorGeometryChange) async throws {
        guard let session, !isChangingGeometry else { throw DeviceHubError.deviceNotReady("Simulator screen is busy.") }
        let generation = runGeneration
        releaseManualTouch()
        isChangingGeometry = true
        defer { if runGeneration == generation { isChangingGeometry = false } }
        await finishRecording()?.value
        guard runGeneration == generation else { throw DeviceHubError.connectionClosed }
        switch change {
        case .posture(let next):
            try await session.setPosture(next)
            if runGeneration == generation { posture = next }
        case .rotation(let direction): try await session.rotate(direction)
        }
        if runGeneration == generation { updateDisplay(session) }
    }

    func touch(_ phase: TouchPhase, at point: CGPoint) {
        guard !isChangingGeometry else { return }
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

    /// Starts recording to the Desktop, or stops and saves the recording in progress.
    func toggleRecording() {
        if recording != nil {
            finishRecording()
            return
        }
        guard canRecord, let session else { return }
        let name = session.device.name
        let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(name) \(Self.timestamp()) \(UUID().uuidString.prefix(8)).mp4")
        do {
            if !session.device.isSimulator, let settings, settings.canRecord {
                recording = try settings.startRecording(to: url)
            } else if let stream, stream.canRecord {
                recording = try stream.startRecording(to: url)
            } else if let settings, settings.canRecord {
                recording = try settings.startRecording(to: url)
            } else { return }
            isRecording = true
        } catch {
            show("\(error)")
        }
    }

    /// Stops a recording in progress and saves it, also when the device goes away.
    @discardableResult
    private func finishRecording() -> Task<Void, Never>? {
        guard let recording else { return nil }
        self.recording = nil
        isRecording = false
        return Task {
            do {
                let url = try await recording.stop()
                show("Saved \(url.lastPathComponent) to the Desktop")
            } catch {
                show("\(error)")
            }
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: Date())
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
