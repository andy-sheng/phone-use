import Foundation

/// A read-only Finder volume. Its lifetime belongs to the device worker, not the RPC connection.
public struct SandboxMount: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let bundleID: String
    public let path: String
    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

public protocol SandboxVolumeAccess: Sendable {
    func mounts() async throws -> [SandboxMount]
    func mount(_ app: SandboxApp) async throws -> SandboxMount
    func unmount(_ volume: SandboxMount) async throws
}

public struct DeviceSandboxVolumes: SandboxVolumeAccess {
    private let device: DeviceSummary

    public init(device: DeviceSummary) throws {
        guard device.isAndroid || !device.isSimulator else {
            throw DeviceHubError.capabilityUnavailable("Finder sandbox mounting requires a physical iOS device or an authorized Android device")
        }
        guard device.isReady else { throw DeviceHubError.deviceNotReady(device.name) }
        self.device = device
    }

    public func mounts() async throws -> [SandboxMount] {
        try await DaemonClient.withClient { try await $0.sandboxMounts(device.udid) }
    }

    public func mount(_ app: SandboxApp) async throws -> SandboxMount {
        let label = String("\(app.name) — \(device.name)".map { "/:\0".contains($0) ? "-" : $0 }.prefix(150))
        return try await DaemonClient.withClient { try await $0.mountSandbox(device.udid, bundleID: app.bundleIdentifier, label: label) }
    }

    public func unmount(_ volume: SandboxMount) async throws {
        try await DaemonClient.withClient { try await $0.unmountSandbox(device.udid, token: volume.id) }
    }

}
