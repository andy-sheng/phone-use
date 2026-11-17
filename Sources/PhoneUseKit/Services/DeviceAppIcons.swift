import Foundation

/// Reads the installed application's actual icon through the shared device connection.
public enum DeviceAppIcons {
    public static func png(device: DeviceSummary, app: SandboxApp) async throws -> Data? {
        let client = try await DaemonClient.connect()
        do {
            let data = try await client.appIcon(device.udid, bundleID: app.bundleIdentifier, version: app.version ?? "")
            await client.close()
            return data
        } catch {
            await client.close()
            throw error
        }
    }
}
