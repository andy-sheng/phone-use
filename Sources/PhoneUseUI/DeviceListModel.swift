import PhoneUseKit
import Foundation

@MainActor
public final class DeviceListModel: ObservableObject {
    @Published public private(set) var devices: [DeviceSummary] = []
    @Published public var selection: DeviceSummary.ID?
    @Published public private(set) var errorMessage: String?
    @Published private(set) var actionInProgress: String?
    @Published var actionError: String?

    public let launcher = DaemonLauncher()

    public init() {}

    public var selectedDevice: DeviceSummary? {
        devices.first { $0.id == selection }
    }

    var availableDevices: [DeviceSummary] { devices.filter(\.isAttached) }
    var unavailableDevices: [DeviceSummary] { devices.filter { !$0.isAttached } }

    /// Starts the daemon and mirrors its device list, reconnecting if the daemon restarts.
    public func run() async {
        while !Task.isCancelled {
            do {
                try await launcher.start()
                errorMessage = nil
                for await update in try await DeviceHub.shared.deviceUpdates() {
                    apply(update)
                }
                errorMessage = "Lost the connection to the \(PhoneUseConfiguration.current.displayName) daemon. Reconnecting…"
            } catch {
                errorMessage = "\(error)"
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func apply(_ update: [DeviceSummary]) {
        devices = update.sorted { ($0.isAttached ? 0 : 1, $0.name) < ($1.isAttached ? 0 : 1, $1.name) }
        if selection == nil || selectedDevice == nil {
            selection = devices.first(where: \.isReady)?.id ?? devices.first(where: \.isAttached)?.id ?? devices.first?.id
        }
    }

    func selectPairedDevice(_ udid: String?) async {
        guard let udid else { return }
        do {
            apply(try await DeviceHub.shared.devices())
            if devices.contains(where: { $0.udid == udid }) { selection = udid }
        } catch {
            actionError = "\(error)"
        }
    }

    /// Runs one onboarding step for the selected device, surfacing failures in the setup view.
    func perform(_ title: String, _ action: @escaping (String) async throws -> Void) {
        guard let udid = selection, actionInProgress == nil else { return }
        actionInProgress = title
        actionError = nil
        Task {
            do {
                try await action(udid)
            } catch {
                actionError = "\(error)"
            }
            actionInProgress = nil
        }
    }

    public func stop() {
        launcher.stop()
    }
}
