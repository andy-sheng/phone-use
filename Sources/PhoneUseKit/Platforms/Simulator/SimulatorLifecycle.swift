import Foundation

/// Simulator management through the same Xcode installation used for discovery and control.
public enum SimulatorLifecycle {
    public static func isAvailable(for device: DeviceSummary) async -> Bool {
        guard let (_, developer) = try? target(device) else { return false }
        return (try? await SimulatorTools.simctl(["help", "shutdown"], developerDirectory: developer)) != nil
    }

    public static func start(_ device: DeviceSummary) async throws {
        let (id, developer) = try target(device)
        // -b boots only if needed. Cancelling this waiter leaves the simulator running.
        try await SimulatorTools.simctl(["bootstatus", id, "-b"], developerDirectory: developer, timeout: .seconds(180))
    }

    public static func shutDown(_ device: DeviceSummary) async throws {
        let (id, developer) = try target(device)
        try await SimulatorTools.simctl(["shutdown", id], developerDirectory: developer)
    }

    public static func restart(_ device: DeviceSummary) async throws {
        if device.isReady {
            try await shutDown(device)
        }
        try await start(device)
    }

    public static func rename(_ device: DeviceSummary, to name: String) async throws {
        let (id, developer) = try target(device)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw DeviceHubError.serviceFailed("Enter a simulator name.") }
        try await SimulatorTools.simctl(["rename", id, name], developerDirectory: developer)
    }

    public static func erase(_ device: DeviceSummary) async throws {
        let (id, developer) = try target(device)
        let current = try await inventoryEntry(id: id, developer: developer)
        if current.state == "Booted" {
            try await SimulatorTools.simctl(["shutdown", id], developerDirectory: developer)
        }
        try await SimulatorTools.simctl(["erase", id], developerDirectory: developer)
    }

    public static func remove(_ device: DeviceSummary) async throws {
        let (id, developer) = try target(device)
        try await SimulatorTools.simctl(["delete", id], developerDirectory: developer)
    }

    public static func directory(for device: DeviceSummary) async throws -> URL {
        let (id, developer) = try target(device)
        let entry = try await inventoryEntry(id: id, developer: developer)
        guard entry.dataPath.hasPrefix("/") else { throw DeviceHubError.serviceFailed("Simulator data path is unavailable.") }
        return URL(fileURLWithPath: entry.dataPath, isDirectory: true).deletingLastPathComponent()
    }

    private static func target(_ device: DeviceSummary) throws -> (String, String) {
        guard device.isSimulator, UUID(uuidString: device.deviceIdentifier) != nil else {
            throw DeviceHubError.capabilityUnavailable("Managing this device as an iOS simulator")
        }
        guard let developer = SimulatorTools.developerDirectory() else {
            throw DeviceHubError.serviceFailed("Xcode is required to manage a simulator")
        }
        return (device.deviceIdentifier, developer)
    }

    private struct Inventory: Decodable {
        struct Entry: Decodable {
            let udid: UUID
            let state: String
            let dataPath: String
        }

        let devices: [String: [Entry]]
    }

    private static func inventoryEntry(id: String, developer: String) async throws -> Inventory.Entry {
        let output = try await SimulatorTools.simctl(["list", "devices", "--json", id], developerDirectory: developer)
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(output.utf8))
        let uuid = UUID(uuidString: id)
        guard let entry = inventory.devices.values.lazy.flatMap({ $0 }).first(where: { $0.udid == uuid }) else {
            throw DeviceHubError.deviceNotFound(id)
        }
        return entry
    }
}
