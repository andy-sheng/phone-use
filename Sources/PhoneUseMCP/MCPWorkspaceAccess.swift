import PhoneUseKit

/// App-owned selection and explicit connection, without making MCP depend on SwiftUI.
public struct MCPWorkspaceAccess: Sendable {
    public let selectedDevice: @Sendable () async -> String?
    public let select: @Sendable (DeviceSummary) async throws -> Void
    public let connect: @Sendable (DeviceSummary) async throws -> Void

    public let endPreview: @Sendable (DeviceSummary) async -> Void
    public let changeGeometry: @Sendable (DeviceSummary, SimulatorGeometryChange) async throws -> Bool

    public init(selectedDevice: @escaping @Sendable () async -> String?,
                select: @escaping @Sendable (DeviceSummary) async throws -> Void,
                connect: @escaping @Sendable (DeviceSummary) async throws -> Void,
                endPreview: @escaping @Sendable (DeviceSummary) async -> Void = { _ in },
                changeGeometry: @escaping @Sendable (DeviceSummary, SimulatorGeometryChange) async throws -> Bool = { _, _ in false }) {
        self.selectedDevice = selectedDevice
        self.select = select
        self.connect = connect
        self.endPreview = endPreview
        self.changeGeometry = changeGeometry
    }
}
