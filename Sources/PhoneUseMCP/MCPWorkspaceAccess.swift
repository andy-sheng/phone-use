import PhoneUseKit

/// App-owned selection and explicit connection, without making MCP depend on SwiftUI.
public struct MCPWorkspaceAccess: Sendable {
    public let selectedDevice: @Sendable () async -> String?
    public let select: @Sendable (DeviceSummary) async throws -> Void
    public let connect: @Sendable (DeviceSummary) async throws -> Void

    public init(selectedDevice: @escaping @Sendable () async -> String?,
                select: @escaping @Sendable (DeviceSummary) async throws -> Void,
                connect: @escaping @Sendable (DeviceSummary) async throws -> Void) {
        self.selectedDevice = selectedDevice
        self.select = select
        self.connect = connect
    }
}
