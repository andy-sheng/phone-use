import Foundation

/// Simulator management through the same Xcode installation used for discovery and control.
public enum SimulatorLifecycle {
    public struct Runtime: Codable, Identifiable, Sendable {
        public struct Model: Codable, Identifiable, Sendable {
            public let identifier: String
            public let name: String
            public let productFamily: String
            public var id: String { identifier }
        }

        public let identifier: String
        public let name: String
        public let version: String
        public let supportedDeviceTypes: [Model]
        public var id: String { identifier }
    }

    public static func creationOptions() async throws -> [Runtime] {
        try await creationOptions(developer: developerDirectory())
    }

    private static func creationOptions(developer: String) async throws -> [Runtime] {
        let output = try await SimulatorTools.simctl(["list", "runtimes", "--json"], developerDirectory: developer)
        return try decodeCreationOptions(Data(output.utf8))
    }

    static func decodeCreationOptions(_ data: Data) throws -> [Runtime] {
        struct Listing: Decodable {
            struct Entry: Decodable {
                let identifier: String
                let name: String
                let version: String
                let isAvailable: Bool
                let supportedDeviceTypes: [Runtime.Model]?
            }
            let runtimes: [Entry]
        }
        return try JSONDecoder().decode(Listing.self, from: data).runtimes.compactMap { entry in
            guard entry.isAvailable, entry.identifier.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-"),
                  let models = entry.supportedDeviceTypes?.filter({ ["iPhone", "iPad"].contains($0.productFamily) }),
                  !models.isEmpty else { return nil }
            return Runtime(identifier: entry.identifier, name: entry.name, version: entry.version, supportedDeviceTypes: models)
        }.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }

    /// Returns the exact discovery identifier. Creation leaves the simulator shut down.
    public static func create(name: String?, deviceType: String, runtime: String) async throws -> String {
        let developer = try developerDirectory()
        let options = try await creationOptions(developer: developer)
        guard let model = options.first(where: { $0.id == runtime })?.supportedDeviceTypes.first(where: { $0.id == deviceType }) else {
            throw DeviceHubError.serviceFailed("The selected simulator model and runtime are unavailable or incompatible.")
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let output = try await SimulatorTools.simctl(["create", trimmed.isEmpty ? model.name : trimmed, deviceType, runtime],
                                                    developerDirectory: developer)
        guard let uuid = UUID(uuidString: output) else {
            throw DeviceHubError.serviceFailed("Xcode did not return the created simulator’s identifier. Check the device list.")
        }
        return "simulator:\(uuid.uuidString)"
    }

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

    static func install(_ app: URL, on device: DeviceSummary) async throws {
        let (id, developer) = try target(device)
        try await SimulatorTools.simctl(["install", id, app.path], developerDirectory: developer)
    }

    private static func target(_ device: DeviceSummary) throws -> (String, String) {
        guard device.isSimulator, UUID(uuidString: device.deviceIdentifier) != nil else {
            throw DeviceHubError.capabilityUnavailable("Managing this device as an iOS simulator")
        }
        return (device.deviceIdentifier, try developerDirectory())
    }

    private static func developerDirectory() throws -> String {
        guard let developer = SimulatorTools.developerDirectory() else {
            throw DeviceHubError.serviceFailed("Xcode is required to manage a simulator")
        }
        return developer
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
