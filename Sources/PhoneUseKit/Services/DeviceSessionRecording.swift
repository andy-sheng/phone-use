import Foundation

extension DeviceSession {
    /// Records the device even when no window is displaying its screen.
    @MainActor
    public func startScreenRecording(to destination: URL) async throws -> any ScreenRecordingSession {
        guard !device.isAndroid else { throw DeviceHubError.capabilityUnavailable("Screen recording on Android") }
        if device.isSimulator {
            return try SimctlSettings(identifier: device.deviceIdentifier, displayIdentifier: simulatorDisplay?.identifier)
                .startRecording(to: destination)
        }
        if let settings = await DeviceSettings.resolve(for: device), settings.canRecord {
            return try settings.startRecording(to: destination)
        }
        guard let stream = await makeVideoScreenStream(for: self) else {
            throw DeviceHubError.capabilityUnavailable("Screen recording on this connection")
        }
        do {
            let recording = try stream.startRecording(to: destination)
            return StreamRecordingOwner(stream: stream, recording: recording)
        } catch {
            stream.stop()
            throw error
        }
    }
}

/// Keep a headless capture alive until its writer finishes, including on failure.
private final class StreamRecordingOwner: ScreenRecordingSession {
    @MainActor private let stream: any ScreenStream
    private let recording: any ScreenRecordingSession
    var destination: URL { recording.destination }
    var isRunning: Bool { recording.isRunning }

    @MainActor init(stream: any ScreenStream, recording: any ScreenRecordingSession) {
        self.stream = stream
        self.recording = recording
    }

    @MainActor func stop() async throws -> URL {
        defer { stream.stop() }
        return try await recording.stop()
    }
}
