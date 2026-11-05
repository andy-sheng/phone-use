import AVFoundation
import CoreMediaIO
import Foundation
import QuartzCore

public enum ScreenStreamKind: String, Sendable {
    /// The display service's HEVC mirror stream, the transport Xcode's Device Hub uses (iOS 27+).
    case mirror = "Mirror"
    /// CoreMediaIO screen capture over USB, the transport QuickTime uses.
    case usb = "USB video"
    /// Repeated PNG screenshots; works everywhere but only reaches a few frames per second.
    case screenshots = "Screenshots"
}

/// A live picture of the device screen rendered into `layer`, which fills its host's bounds.
@MainActor
public protocol ScreenStream: AnyObject {
    var kind: ScreenStreamKind { get }
    var layer: CALayer { get }
    /// Only reported by sources that deliver discrete frames.
    var onFrame: ((Double) -> Void)? { get set }
    func start() async throws
    func stop()
}

/// Starts the best available screen source for the device, falling back in order of quality.
@MainActor
public func makeScreenStream(for session: DeviceSession) async -> any ScreenStream {
    if let video = await makeVideoScreenStream(for: session) {
        return video
    }
    let fallback = ScreenshotScreenStream(session: session)
    try? await fallback.start()
    return fallback
}

/// Starts the best video source (mirror, then USB capture), or returns nil when none works.
@MainActor
public func makeVideoScreenStream(for session: DeviceSession) async -> (any ScreenStream)? {
    var candidates: [any ScreenStream] = []
    if session.device.osMajorVersion >= 27 {
        candidates.append(MirrorScreenStream(session: session))
    }
    if session.device.isWired {
        candidates.append(USBScreenStream(udid: session.device.udid, name: session.device.name))
    }
    for candidate in candidates {
        do {
            try await candidate.start()
            return candidate
        } catch {
            candidate.stop()
            FileHandle.standardError.write(Data("\(candidate.kind.rawValue) unavailable: \(error)\n".utf8))
        }
    }
    return nil
}

// MARK: - Mirror stream

/// Renders the daemon's `/stream.bin`: frames of `[u32 BE length][kind][HEVC NAL units, each
/// prefixed by a u32 BE length]`, where kind 0 is a keyframe, 1 a delta and 2 a keyframe that
/// follows dropped data and needs a decoder reset.
@MainActor
final class MirrorScreenStream: ScreenStream {
    let kind = ScreenStreamKind.mirror
    var onFrame: ((Double) -> Void)?
    var layer: CALayer { displayLayer }

    private let session: DeviceSession
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var readTask: Task<Void, Never>?

    init(session: DeviceSession) {
        self.session = session
        displayLayer.videoGravity = .resize
    }

    func start() async throws {
        let url = try await session.mirrorURL()
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DeviceHubError.serviceFailed("The mirror stream is not available")
        }
        let renderer = displayLayer.sampleBufferRenderer
        let owner = WeakBox(self)
        readTask = Task.detached {
            var decoder = HEVCSampleBuilder()
            var meter = FrameMeter()
            do {
                var iterator = bytes.makeAsyncIterator()
                while !Task.isCancelled {
                    let header = try await Self.read(4, from: &iterator)
                    let length = header.reduce(0) { $0 << 8 | Int($1) }
                    guard length > 0 else { continue }
                    let frame = try await Self.read(length, from: &iterator)
                    let frameKind = frame[frame.startIndex]
                    if frameKind == 2 { renderer.flush() }
                    guard let sample = decoder.sample(fromAccessUnit: frame.dropFirst(), isKey: frameKind != 1) else { continue }
                    if renderer.status == .failed { renderer.flush() }
                    renderer.enqueue(sample)
                    if let fps = meter.tick() {
                        await MainActor.run { owner.value?.onFrame?(fps) }
                    }
                }
            } catch {
                FileHandle.standardError.write(Data("mirror stream ended: \(error)\n".utf8))
            }
        }
    }

    func stop() {
        readTask?.cancel()
        readTask = nil
    }

    private nonisolated static func read(_ count: Int, from iterator: inout URLSession.AsyncBytes.AsyncIterator) async throws -> Data {
        var data = Data(capacity: count)
        while data.count < count {
            guard let byte = try await iterator.next() else { throw DeviceHubError.connectionClosed }
            data.append(byte)
        }
        return data
    }
}

/// Turns length-prefixed HEVC access units into sample buffers, tracking the parameter sets.
struct HEVCSampleBuilder {
    private var format: CMVideoFormatDescription?

    mutating func sample(fromAccessUnit unit: Data, isKey: Bool) -> CMSampleBuffer? {
        var parameterSets: [UInt8: Data] = [:]
        var payload = Data()
        var index = unit.startIndex
        while index + 4 <= unit.endIndex {
            let length = unit[index ..< index + 4].reduce(0) { $0 << 8 | Int($1) }
            index += 4
            guard length > 0, index + length <= unit.endIndex else { break }
            let nal = unit[index ..< index + length]
            index += length
            let type = (nal[nal.startIndex] >> 1) & 0x3F
            if (32...34).contains(type) {
                parameterSets[type] = Data(nal)
            } else {
                payload.appendBE(UInt32(length))
                payload.append(nal)
            }
        }
        if let vps = parameterSets[32], let sps = parameterSets[33], let pps = parameterSets[34] {
            format = Self.formatDescription(vps: vps, sps: sps, pps: pps) ?? format
        }
        guard let format, !payload.isEmpty else { return nil }
        return Self.sampleBuffer(payload, format: format, isKey: isKey)
    }

    private static func formatDescription(vps: Data, sps: Data, pps: Data) -> CMVideoFormatDescription? {
        let sets = [vps, sps, pps]
        var description: CMVideoFormatDescription?
        let status = sets[0].withUnsafeBytes { v in
            sets[1].withUnsafeBytes { s in
                sets[2].withUnsafeBytes { p in
                    let pointers = [v, s, p].map { $0.bindMemory(to: UInt8.self).baseAddress! }
                    let sizes = sets.map(\.count)
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault, parameterSetCount: 3, parameterSetPointers: pointers,
                        parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                        formatDescriptionOut: &description)
                }
            }
        }
        return status == noErr ? description : nil
    }

    private static func sampleBuffer(_ payload: Data, format: CMVideoFormatDescription, isKey: Bool) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKey {
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}

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

// MARK: - USB screen capture

@MainActor
public enum USBScreenCapture {
    private static var preparedAt: Date?

    /// Opting in makes wired iOS devices re-enumerate over USB, which drops their tunnel and every
    /// service connection through it. Call this before opening sessions.
    public static func prepare() {
        guard preparedAt == nil else { return }
        preparedAt = Date()
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    /// Waits out the re-enumeration triggered by `prepare()`; observed to take about three seconds.
    public static func waitUntilSettled() async {
        guard let preparedAt else { return }
        let remaining = 4 - Date().timeIntervalSince(preparedAt)
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }
    }
}

@MainActor
final class USBScreenStream: ScreenStream {
    let kind = ScreenStreamKind.usb
    var onFrame: ((Double) -> Void)?
    var layer: CALayer { previewLayer }

    private let udid: String
    private let name: String
    private let captureSession = AVCaptureSession()
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(udid: String, name: String) {
        self.udid = udid
        self.name = name
        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer.videoGravity = .resize
    }

    func start() async throws {
        USBScreenCapture.prepare()
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            throw DeviceHubError.capabilityUnavailable("camera access for USB screen capture was denied")
        }
        let device = try await findCaptureDevice()
        let input = try AVCaptureDeviceInput(device: device)
        captureSession.beginConfiguration()
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw DeviceHubError.capabilityUnavailable("USB screen capture input")
        }
        captureSession.addInput(input)
        captureSession.commitConfiguration()
        let session = captureSession
        await Task.detached { session.startRunning() }.value
    }

    func stop() {
        let session = captureSession
        Task.detached { session.stopRunning() }
    }

    /// Capture devices show up asynchronously after `USBScreenCapture.prepare()`.
    private func findCaptureDevice() async throws -> AVCaptureDevice {
        let wanted = udid.replacingOccurrences(of: "-", with: "").lowercased()
        for _ in 0..<30 {
            let devices = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: .muxed, position: .unspecified
            ).devices
            if let match = devices.first(where: {
                $0.uniqueID.replacingOccurrences(of: "-", with: "").lowercased() == wanted
            }) ?? devices.first(where: { $0.localizedName == name }) {
                return match
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw DeviceHubError.capabilityUnavailable("USB screen capture device for \(name)")
    }
}

// MARK: - Screenshot polling

@MainActor
final class ScreenshotScreenStream: ScreenStream {
    let kind = ScreenStreamKind.screenshots
    let layer = CALayer()
    var onFrame: ((Double) -> Void)?

    private let session: DeviceSession
    private var pollTask: Task<Void, Never>?

    init(session: DeviceSession) {
        self.session = session
        layer.contentsGravity = .resize
    }

    func start() async throws {
        let session = session
        pollTask = Task { [weak self] in
            var fps = 0.0
            while !Task.isCancelled {
                let start = Date()
                guard let image = try? await session.screenshot() else {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                guard let self, !Task.isCancelled else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.layer.contents = image
                CATransaction.commit()
                let current = 1 / max(Date().timeIntervalSince(start), 0.001)
                fps = fps == 0 ? current : fps * 0.8 + current * 0.2
                self.onFrame?(fps)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}
