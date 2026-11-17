import AVFoundation
import Foundation
import QuartzCore

/// Renders the daemon's `/stream.bin`: frames of `[u32 BE length][kind][HEVC NAL units, each
/// prefixed by a u32 BE length]`, where kind 0 is a keyframe, 1 a delta and 2 a keyframe that
/// follows dropped data and needs a decoder reset.
@MainActor
final class MirrorScreenStream: ScreenStream {
    let kind = ScreenStreamKind.mirror
    var onFrame: ((Double) -> Void)?
    var onError: ((String) -> Void)?
    var layer: CALayer { displayLayer }

    private let session: DeviceSession
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var readTask: Task<Void, Never>?
    private let recordingSink = ScreenRecordingSink()
    var canRecord: Bool { true }
    func copyFrame() -> CGImage? { recordingSink.frameCapture.copyFrame() }
    func copyPixelBuffer() -> CVPixelBuffer? { recordingSink.frameCapture.copyPixelBuffer() }

    func startRecording(to destination: URL) throws -> any ScreenRecordingSession {
        try recordingSink.start(to: destination)
    }

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
        let recordingSink = recordingSink
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
                    if frameKind == 2 {
                        recordingSink.frameCapture.reset()
                        renderer.flush()
                        recordingSink.fail("The video stream dropped frames. Start a new recording.")
                    }
                    guard let sample = decoder.sample(fromAccessUnit: frame.dropFirst(), isKey: frameKind != 1) else { continue }
                    if renderer.status == .failed { renderer.flush() }
                    renderer.enqueue(sample)
                    recordingSink.append(sample)
                    if let fps = meter.tick() {
                        await MainActor.run { owner.value?.onFrame?(fps) }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    recordingSink.fail("The video stream ended: \(error)")
                    await MainActor.run { owner.value?.onError?("The video stream ended: \(error)") }
                }
                FileHandle.standardError.write(Data("mirror stream ended: \(error)\n".utf8))
            }
        }
    }

    func stop() {
        recordingSink.frameCapture.reset()
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
        return VideoSampleBuffer.make(payload, format: format, isKey: isKey)
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

}
