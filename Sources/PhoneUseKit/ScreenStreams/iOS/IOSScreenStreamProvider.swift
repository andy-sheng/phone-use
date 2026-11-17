import Foundation

@MainActor
enum IOSScreenStreamProvider {
    static func prepare(_ device: DeviceSummary) async {
        if device.isWired {
            USBScreenCapture.prepare()
            await USBScreenCapture.waitUntilSettled()
        }
        await DeviceHub.shared.closeSession(for: device.udid)
    }

    static func makeStream(_ session: DeviceSession) async -> any ScreenStream {
        if let video = await makeVideo(session) { return video }
        let fallback = ScreenshotScreenStream(session: session, recoveryPolicy: .retryVideo, stopOnError: false)
        try? await fallback.start()
        return fallback
    }

    static func makeVideo(_ session: DeviceSession, captureFrames: Bool = false) async -> (any ScreenStream)? {
        var candidates: [any ScreenStream] = []
        if session.device.osMajorVersion >= 27 { candidates.append(MirrorScreenStream(session: session)) }
        if session.device.isWired {
            candidates.append(USBScreenStream(udid: session.device.udid, name: session.device.name))
        }
        for candidate in candidates {
            guard !Task.isCancelled else { return nil }
            do {
                if captureFrames { _ = candidate.copyFrame() }
                try await candidate.start()
                return candidate
            } catch {
                candidate.stop()
                FileHandle.standardError.write(Data("\(candidate.kind.rawValue) unavailable: \(error)\n".utf8))
            }
        }
        return nil
    }
}
