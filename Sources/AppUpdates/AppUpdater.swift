import Combine
import Foundation
import Sparkle

/// One updater for the lifetime of the packaged app. Bare `swift run` binaries have
/// no installable bundle and deliberately leave update checks disabled.
@MainActor
public final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published public private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?
    private var taskRunning = false
    private var pendingInstallation: (() -> Void)?

    public override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") is String,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        controller.startUpdater()
    }

    public func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    public func setTaskRunning(_ running: Bool) {
        taskRunning = running
        if !running, let install = pendingInstallation {
            pendingInstallation = nil
            install()
        }
    }

    func deferInstallationIfTaskRunning(_ install: @escaping () -> Void) -> Bool {
        guard taskRunning else { return false }
        pendingInstallation = install
        return true
    }

    public func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                        untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        deferInstallationIfTaskRunning(installHandler)
    }
}
