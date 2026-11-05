import Foundation

/// An unpaired Bonjour advertisement, scoped to an explicit nearby pairing session.
public struct NearbyDevice: Decodable, Identifiable, Sendable {
    public let id: String
    public let name: String
}

public struct WirelessPairingStatus: Decodable, Sendable {
    public enum State: String, Decodable, Sendable {
        case waiting, pairing, paired, failed, cancelled
    }

    public let sessionID: String
    public let state: State
    public let hostName: String
    public let pin: String?
    public let devices: [NearbyDevice]
    public let pairedUDID: String?
    public let deviceName: String?
    public let error: String?
    public let discoveryError: String?

    public var isActive: Bool { state == .waiting || state == .pairing }
}
