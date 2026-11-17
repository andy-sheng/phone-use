import Foundation

@MainActor
enum AndroidScreenStreamProvider {
    static func prepare(_ device: DeviceSummary) async {
        // Preserve the shared controller while automation or another preview is using it.
    }

    static func makeStream(_ session: DeviceSession) async -> any ScreenStream {
        let video = AndroidScrcpyScreenStream(session: session)
        do {
            try await video.start()
            return video
        } catch {
            video.stop()
            let message = "Android video unavailable: \(error). Using screenshot preview."
            let fallback = ScreenshotScreenStream(session: session, recoveryPolicy: .none,
                                                   statusMessage: message, stopOnError: true)
            if !Task.isCancelled { try? await fallback.start() }
            return fallback
        }
    }

    static func makeVideo(_ session: DeviceSession, captureFrames: Bool = false) async -> (any ScreenStream)? {
        let stream = AndroidScrcpyScreenStream(session: session)
        do {
            if captureFrames { _ = stream.copyFrame() }
            try await stream.start()
            return stream
        } catch {
            stream.stop()
            return nil
        }
    }
}
