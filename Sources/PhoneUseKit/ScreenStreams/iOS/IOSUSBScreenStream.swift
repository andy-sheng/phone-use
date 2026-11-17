import AVFoundation
import CoreMediaIO
import Foundation
import QuartzCore

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
    var onError: ((String) -> Void)?
    var layer: CALayer { previewLayer }

    private let udid: String
    private let name: String
    private let captureSession = AVCaptureSession()
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let recordingSink = ScreenRecordingSink()
    private var recordingAvailable = false
    var canRecord: Bool { recordingAvailable }
    func copyFrame() -> CGImage? { recordingSink.frameCapture.copyFrame() }
    func copyPixelBuffer() -> CVPixelBuffer? { recordingSink.frameCapture.copyPixelBuffer() }

    func startRecording(to destination: URL) throws -> any ScreenRecordingSession {
        guard canRecord else { throw DeviceHubError.capabilityUnavailable("USB screen recording") }
        return try recordingSink.start(to: destination)
    }

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
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(recordingSink, queue: DispatchQueue(label: "phoneuse.usb.recording"))
        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
            recordingAvailable = true
        }
        captureSession.commitConfiguration()
        let session = captureSession
        await Task.detached { session.startRunning() }.value
    }

    func stop() {
        recordingSink.frameCapture.reset()
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
