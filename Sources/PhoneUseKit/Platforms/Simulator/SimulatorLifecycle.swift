import Foundation

/// Explicit simulator power actions, shared by both applications.
public enum SimulatorLifecycle {
    public static func start(_ device: DeviceSummary) async throws {
        guard device.isSimulator, UUID(uuidString: device.deviceIdentifier) != nil else {
            throw DeviceHubError.capabilityUnavailable("Starting this device as an iOS simulator")
        }
        guard let developer = SimulatorTools.developerDirectory() else {
            throw DeviceHubError.serviceFailed("Xcode is required to start a simulator")
        }
        // -b boots only if needed, so another app starting the same device is harmless.
        // Cancelling this waiter leaves the simulator running, as Simulator.app does.
        try await SimulatorTools.simctl(["bootstatus", device.deviceIdentifier, "-b"],
                                        developerDirectory: developer, timeout: .seconds(180))
    }
}
