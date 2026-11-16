import Foundation

/// One authenticated, loopback-only video connection. The token is also the release lease:
/// stopping an older preview cannot tear down a newer preview of the same device.
public struct AndroidVideoEndpoint: Decodable, Sendable {
    public let port: UInt16
    public let token: String

    public init(port: UInt16, token: String) {
        self.port = port
        self.token = token
    }
}
