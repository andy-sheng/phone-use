import Foundation

/// Entry point: device list, onboarding actions, and one cached session per device.
public actor DeviceHub {
    public static let shared = DeviceHub()

    private var client: DaemonClient?
    private var sessions: [String: DeviceSession] = [:]

    public func daemon() async throws -> DaemonClient {
        if let client, await client.isConnected {
            return client
        }
        sessions.removeAll()
        let connected = try await DaemonClient.connect()
        client = connected
        return connected
    }

    public func devices() async throws -> [DeviceSummary] {
        try await daemon().devices()
    }

    /// Read-only. Listing devices must not boot a simulator or open a device session.
    public func lockStatus(for device: DeviceSummary) async -> DeviceLockStatus {
        guard device.isReady else { return DeviceLockStatus(.unknown) }
        if device.isAndroid || device.isSimulator {
            let locked: Bool?
            if device.isAndroid {
                locked = try? await daemon().androidScreenLocked(device.udid)
            } else {
                locked = try? await device.simulatorScreenLocked()
            }
            return DeviceLockStatus(locked.map { $0 ? .locked : .unlocked } ?? .unknown)
        }
        let status = (try? await device.physicalLockStatus()) ?? DeviceLockStatus(.unknown)
        guard status.state == .unknown, let locked = try? await sessions[device.udid]?.physicalScreenLock() else {
            return status
        }
        return DeviceLockStatus(locked ? .locked : .unlocked, passcodeRequired: status.passcodeRequired,
                                unlockedSinceBoot: status.unlockedSinceBoot)
    }

    public func deviceUpdates() async throws -> AsyncStream<[DeviceSummary]> {
        try await daemon().deviceUpdates()
    }

    /// Resolves `query` against UDID or name; `nil` picks the first ready device.
    public func session(for query: String? = nil) async throws -> DeviceSession {
        let device = try await resolve(query)
        if let session = sessions[device.udid] {
            return session
        }
        guard device.isReady else {
            throw DeviceHubError.deviceNotReady("\(device.name) is not ready (\(device.state.rawValue))")
        }
        let session = try await DeviceSession.open(device, daemon: daemon())
        sessions[device.udid] = session
        return session
    }

    /// Resolves `query` like `session(for:)` without opening a session.
    public func device(for query: String? = nil) async throws -> DeviceSummary {
        try await resolve(query)
    }

    public func androidADBPath() async throws -> String {
        try await daemon().androidADBPath()
    }

    public func closeSession(for udid: String) async {
        await sessions.removeValue(forKey: udid)?.close()
    }

    /// Explicit reconnect also clears the daemon's geometry snapshot. Ordinary preview closure
    /// leaves the worker alive because an automation run may still be using it.
    public func resetSession(for udid: String) async throws {
        await closeSession(for: udid)
        try await daemon().closeDevice(udid)
    }

    public func pair(_ udid: String) async throws {
        try await daemon().pair(udid)
    }

    public func revealDeveloperMode(_ udid: String) async throws {
        try await daemon().revealDeveloperMode(udid)
    }

    /// Lets macOS reach the device over Wi-Fi on its own; the device must be on USB.
    public func setSystemWifi(_ udid: String, enabled: Bool) async throws {
        try await daemon().setSystemWifi(udid, enabled: enabled)
    }

    public func mountDeveloperImage(_ udid: String) async throws {
        try await daemon().mountDeveloperImage(udid)
    }

    private func resolve(_ query: String?) async throws -> DeviceSummary {
        let devices = try await self.devices()
        guard let query, !query.isEmpty else {
            guard let device = devices.first(where: \.isReady) ?? devices.first(where: \.isAttached) else {
                throw DeviceHubError.deviceNotFound("<any connected device>")
            }
            return device
        }
        let needle = query.lowercased()
        let match = devices.first { $0.udid.lowercased() == needle }
            ?? devices.first { $0.deviceIdentifier.lowercased() == needle }
            ?? devices.first { $0.name.lowercased() == needle }
            ?? devices.first { $0.name.lowercased().contains(needle) }
        guard let match else { throw DeviceHubError.deviceNotFound(query) }
        return match
    }
}
