import Foundation

/// Network Link conditions reported by Instruments on a physical iPhone or iPad.
public struct DeviceNetworkCondition: Decodable, Sendable {
    public struct Profile: Decodable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let detail: String
    }

    public let profiles: [Profile]
    public let activeProfile: String?
    /// True when this device worker owns the active network condition.
    public let owned: Bool
    /// Includes conditions owned by Xcode and non-network conditions such as thermal state.
    public let inUse: Bool
}

extension DeviceSummary {
    public func networkCondition() async throws -> DeviceNetworkCondition {
        try await runNetworkCondition("networkCondition")
    }

    /// Passing nil ends the network condition started by this worker.
    public func setNetworkCondition(_ profile: String?) async throws -> DeviceNetworkCondition {
        try await runNetworkCondition(profile == nil ? "disableNetworkCondition" : "enableNetworkCondition", profile: profile)
    }

    private func runNetworkCondition(_ method: String, profile: String? = nil) async throws -> DeviceNetworkCondition {
        guard platform == .ios, !isSimulator, isReady else {
            throw DeviceHubError.capabilityUnavailable("Network Link requires a ready physical iPhone or iPad")
        }
        return try await DaemonClient.withClient {
            try await $0.networkCondition(method, udid: udid, profile: profile)
        }
    }
}
