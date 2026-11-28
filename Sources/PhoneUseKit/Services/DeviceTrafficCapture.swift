import Foundation

/// One TCP or UDP connection observed by a physical iPhone or iPad's packet capture service.
/// HTTPS payloads stay encrypted; `host` comes from TLS SNI, DNS answers or an HTTP `Host` header.
public struct DeviceTrafficFlow: Decodable, Identifiable, Sendable, Equatable {
    public struct Request: Decodable, Sendable, Equatable {
        public let method: String
        /// Plaintext HTTP only, including the query string.
        public let url: String
        public let status: Int?
    }

    public let id: Int
    /// The process that owns the socket, such as `nsurlsessiond`.
    public let process: String
    public let pid: Int
    /// The app a system daemon acts for, when the kernel reports a different effective process.
    public let app: String?
    public let interface: String
    public let `protocol`: String
    /// `tls`, `http`, `quic`, `dns`, `tcp` or `udp`.
    public let kind: String
    public let host: String?
    public let remote: String
    public let remotePort: Int
    public let localPort: Int
    public let firstSeen: Double
    public let lastSeen: Double
    /// Transport payload bytes, excluding IP and TCP/UDP headers.
    public let sent: Int
    public let received: Int
    public let packets: Int
    public let closed: Bool
    public let requests: [Request]
}

public struct DeviceTrafficSnapshot: Decodable, Sendable {
    /// Changes when the capture restarts or is cleared; cursors from another session are invalid.
    public let session: String
    public let running: Bool
    public let error: String?
    public let packets: Int
    /// Flows changed after the requested cursor, oldest change first.
    public let flows: [DeviceTrafficFlow]
    public let nextCursor: Int
    public let hasMore: Bool
}

public enum DeviceTrafficAction: String, Sendable {
    case start, stop, clear, read
}

extension DeviceSummary {
    /// Live capture requires a USB connection; a Wi-Fi link would capture its own stream.
    public func trafficCapture(_ action: DeviceTrafficAction, after cursor: Int = 0) async throws -> DeviceTrafficSnapshot {
        guard platform == .ios, !isSimulator, isReady else {
            throw DeviceHubError.capabilityUnavailable("Traffic capture requires a ready physical iPhone or iPad")
        }
        return try await DaemonClient.withClient {
            try await $0.trafficCapture(udid: udid, action: action.rawValue, after: cursor)
        }
    }
}
