import CoreGraphics
import Foundation
import QuartzCore

@MainActor
final class ScreenshotScreenStream: ScreenStream {
    typealias Screenshot = @Sendable () async throws -> CGImage

    let kind = ScreenStreamKind.screenshots
    let layer = CALayer()
    var onFrame: ((Double) -> Void)?
    var onError: ((String) -> Void)? {
        didSet {
            if let terminalError { onError?(terminalError) }
        }
    }
    private(set) var terminalError: String?

    let recoveryPolicy: ScreenStreamRecoveryPolicy
    let statusMessage: String?
    private let stopOnError: Bool
    private let screenshot: Screenshot
    private var pollTask: Task<Void, Never>?

    convenience init(session: DeviceSession, recoveryPolicy: ScreenStreamRecoveryPolicy,
                     statusMessage: String? = nil, stopOnError: Bool) {
        self.init(recoveryPolicy: recoveryPolicy, statusMessage: statusMessage,
                  stopOnError: stopOnError, screenshot: { try await session.screenshot() })
    }

    init(recoveryPolicy: ScreenStreamRecoveryPolicy, statusMessage: String? = nil,
         stopOnError: Bool, screenshot: @escaping Screenshot) {
        self.recoveryPolicy = recoveryPolicy
        self.statusMessage = statusMessage
        self.stopOnError = stopOnError
        self.screenshot = screenshot
        layer.contentsGravity = .resize
    }

    func start() async throws {
        stop()
        let screenshot = screenshot
        let stopOnError = stopOnError
        pollTask = Task { [weak self] in
            var fps = 0.0
            while !Task.isCancelled {
                let start = Date()
                let image: CGImage
                do {
                    image = try await screenshot()
                } catch {
                    guard !Task.isCancelled else { return }
                    if stopOnError {
                        let message = String(describing: error)
                        self?.terminalError = message
                        self?.onError?(message)
                        return
                    }
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
        terminalError = nil
    }
}
