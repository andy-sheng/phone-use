import AVFoundation
import Foundation
import QuartzCore

protocol ScrcpyVideoTransport: AnyObject, Sendable {
    func open() async throws
    func write(_ data: Data) async throws
    func read(exactly count: Int) async throws -> Data
    func close()
}

private final class ScrcpyByteStream: ScrcpyVideoTransport, @unchecked Sendable {
    private let stream: ByteStream
    init(port: UInt16) { stream = ByteStream(port: port) }
    func open() async throws { try await stream.open() }
    func write(_ data: Data) async throws { try await stream.write(data) }
    func read(exactly count: Int) async throws -> Data { try await stream.read(exactly: count) }
    func close() { stream.close() }
}

@MainActor
final class AndroidScrcpyScreenStream: ScreenStream {
    typealias StartEndpoint = @Sendable () async throws -> AndroidVideoEndpoint
    typealias StopEndpoint = @Sendable (String) async -> Void
    typealias TransportFactory = @Sendable (UInt16) -> any ScrcpyVideoTransport

    let kind = ScreenStreamKind.scrcpy
    var onFrame: ((Double) -> Void)?
    var onError: ((String) -> Void)? {
        didSet {
            // The stream may fail after start returns but before its view attaches callbacks.
            if started, let failure { onError?(failure) }
        }
    }
    var layer: CALayer { displayLayer }
    private(set) var hasDecodedFrame = false
    private let frameCapture = ScreenFrameCapture()
    func copyFrame() -> CGImage? { frameCapture.copyFrame() }
    func copyPixelBuffer() -> CVPixelBuffer? { frameCapture.copyPixelBuffer() }

    private let display: DisplayInfo
    private let startEndpoint: StartEndpoint
    private let stopEndpoint: StopEndpoint
    private let transportFactory: TransportFactory
    private let startupTimeout: Duration
    private var displayLayer = AVSampleBufferDisplayLayer()
    private var generation: UUID?
    private var token: String?
    private var transport: (any ScrcpyVideoTransport)?
    private var connectionTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var failure: String?
    private var started = false

    convenience init(session: DeviceSession) {
        self.init(display: session.display, startEndpoint: { try await session.startAndroidVideo() },
                  stopEndpoint: { token in await session.stopAndroidVideo(token: token) })
    }

    init(display: DisplayInfo, startupTimeout: Duration = .seconds(12),
         startEndpoint: @escaping StartEndpoint, stopEndpoint: @escaping StopEndpoint,
         transportFactory: @escaping TransportFactory = { ScrcpyByteStream(port: $0) }) {
        self.display = display
        self.startupTimeout = startupTimeout
        self.startEndpoint = startEndpoint
        self.stopEndpoint = stopEndpoint
        self.transportFactory = transportFactory
        displayLayer.videoGravity = .resizeAspect
    }

    /// Each start owns a fresh `generation`. Work belonging to an older generation (a late
    /// endpoint, decoded frame or failure) checks it and discards itself instead of touching
    /// the current stream. Tasks hold the stream weakly so an abandoned stream can deallocate.
    func start() async throws {
        stop()
        let id = UUID()
        generation = id
        failure = nil
        started = false
        hasDecodedFrame = false
        // A new layer cannot accidentally report readiness from the previous generation.
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        connectionTask = Self.connect(owner: WeakBox(self), generation: id,
                                      startEndpoint: startEndpoint, stopEndpoint: stopEndpoint)
        do {
            try await waitForFirstFrame(generation: id)
            started = true
            monitorRenderer(generation: id)
        } catch {
            if generation == id { stop() }
            throw error
        }
    }

    private static func connect(owner: WeakBox<AndroidScrcpyScreenStream>, generation id: UUID,
                                startEndpoint: @escaping StartEndpoint,
                                stopEndpoint: @escaping StopEndpoint) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                let endpoint = try await startEndpoint()
                guard let stream = owner.value, stream.generation == id, !Task.isCancelled else {
                    await stopEndpoint(endpoint.token)
                    return
                }
                stream.token = endpoint.token
                let transport = stream.transportFactory(endpoint.port)
                stream.transport = transport
                try await transport.open()
                guard stream.generation == id, !Task.isCancelled else { transport.close(); return }
                try await transport.write(Data((endpoint.token + "\n").utf8))
                guard stream.generation == id, !Task.isCancelled else { transport.close(); return }
                stream.readTask = AndroidScrcpyScreenStream.decode(
                    transport, display: stream.display, renderer: stream.displayLayer.sampleBufferRenderer,
                    frameCapture: stream.frameCapture,
                    owner: owner, generation: id)
            } catch {
                guard !Task.isCancelled else { return }
                owner.value?.failed(String(describing: error), generation: id)
            }
        }
    }

    /// Reads and renders packets off the main actor until cancelled or the stream fails.
    private static func decode(_ transport: any ScrcpyVideoTransport, display: DisplayInfo,
                               renderer: AVSampleBufferVideoRenderer,
                               frameCapture: ScreenFrameCapture,
                               owner: WeakBox<AndroidScrcpyScreenStream>, generation id: UUID) -> Task<Void, Never> {
        Task.detached {
            do {
                let metadata = try ScrcpyVideoMetadata(await transport.read(exactly: 12))
                try AndroidVideoGeometry.validate(width: metadata.width, height: metadata.height, display: display)
                var decoder = H264SampleBuilder(display: display)
                var verifyNextFrame = true
                var publishedFirstFrame = false
                var meter = FrameMeter()
                while !Task.isCancelled {
                    let header = try ScrcpyPacketHeader(await transport.read(exactly: 12))
                    let payload = try await transport.read(exactly: header.payloadSize)
                    try Task.checkCancellation()
                    let packet = try decoder.packet(payload, header: header)
                    if packet.formatChanged { renderer.flush(); verifyNextFrame = true }
                    guard let sample = packet.sample else { continue }
                    frameCapture.append(sample)
                    if verifyNextFrame {
                        try H264FirstFrameDecoder.verify(sample)
                        verifyNextFrame = false
                    }
                    guard renderer.status != .failed else {
                        throw ScrcpyVideoError.decoder(renderer.error?.localizedDescription ?? "renderer rejected a frame")
                    }
                    if !renderer.isReadyForMoreMediaData {
                        // Bound decoder latency. After dropping dependent frames, resume at an IDR.
                        renderer.flush()
                        if !packet.isKeyframe { decoder.requireKeyframe(); continue }
                    }
                    renderer.enqueue(sample)
                    if !publishedFirstFrame {
                        publishedFirstFrame = true
                        await owner.value?.firstFrameDecoded(generation: id)
                    }
                    if let fps = meter.tick() {
                        await owner.value?.frameRateMeasured(fps, generation: id)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await owner.value?.failed(String(describing: error), generation: id)
            }
        }
    }

    private func firstFrameDecoded(generation id: UUID) {
        if generation == id { hasDecodedFrame = true }
    }

    private func frameRateMeasured(_ fps: Double, generation id: UUID) {
        if generation == id { onFrame?(fps) }
    }

    private func waitForFirstFrame(generation id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: startupTimeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            if let failure { throw DeviceHubError.serviceFailed(failure) }
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                throw ScrcpyVideoError.decoder(renderer.error?.localizedDescription ?? "first frame could not be decoded")
            }
            if hasDecodedFrame { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw DeviceHubError.timeout("waiting for the first decoded Android video frame")
    }

    func stop() {
        frameCapture.reset()
        generation = nil
        started = false
        connectionTask?.cancel()
        connectionTask = nil
        readTask?.cancel()
        readTask = nil
        healthTask?.cancel()
        healthTask = nil
        transport?.close()
        transport = nil
        releaseEndpoint()
        displayLayer.sampleBufferRenderer.flush()
    }

    private func failed(_ message: String, generation id: UUID) {
        guard generation == id, failure == nil else { return }
        failure = message
        readTask?.cancel()
        healthTask?.cancel()
        transport?.close()
        transport = nil
        releaseEndpoint()
        if started { onError?(message) }
    }

    private func monitorRenderer(generation id: UUID) {
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.generation == id else { return }
                let renderer = self.displayLayer.sampleBufferRenderer
                if renderer.status == .failed {
                    self.failed(ScrcpyVideoError.decoder(renderer.error?.localizedDescription ?? "renderer failed").description,
                                generation: id)
                    return
                }
            }
        }
    }

    private func releaseEndpoint() {
        guard let token else { return }
        self.token = nil
        let stopEndpoint = stopEndpoint
        Task { await stopEndpoint(token) }
    }
}
