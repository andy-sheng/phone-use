import Foundation

/// The subset of HTTP/2 framing RemoteXPC uses (RFC 9113 §4.1).
struct HTTP2Frame {
    enum Kind: UInt8 {
        case data = 0x0
        case headers = 0x1
        case rstStream = 0x3
        case settings = 0x4
        case ping = 0x6
        case goAway = 0x7
        case windowUpdate = 0x8
    }

    static let headerSize = 9
    static let preface = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
    static let endStream: UInt8 = 0x1
    static let ack: UInt8 = 0x1
    static let endHeaders: UInt8 = 0x4
    static let settingsMaxConcurrentStreams: UInt16 = 0x3
    static let settingsInitialWindowSize: UInt16 = 0x4

    var rawKind: UInt8
    var flags: UInt8
    var streamID: UInt32
    var payload: Data

    var kind: Kind? { Kind(rawValue: rawKind) }

    init(_ kind: Kind, flags: UInt8 = 0, stream streamID: UInt32, payload: Data = Data()) {
        rawKind = kind.rawValue
        self.flags = flags
        self.streamID = streamID
        self.payload = payload
    }

    init(rawKind: UInt8, flags: UInt8, streamID: UInt32, payload: Data) {
        self.rawKind = rawKind
        self.flags = flags
        self.streamID = streamID
        self.payload = payload
    }

    static func settings(_ values: [(UInt16, UInt32)]) -> HTTP2Frame {
        var payload = Data()
        for (identifier, value) in values {
            payload.appendBE(identifier)
            payload.appendBE(value)
        }
        return HTTP2Frame(.settings, stream: 0, payload: payload)
    }

    static func windowUpdate(stream: UInt32, increment: UInt32) -> HTTP2Frame {
        var payload = Data()
        payload.appendBE(increment & 0x7FFF_FFFF)
        return HTTP2Frame(.windowUpdate, stream: stream, payload: payload)
    }

    func serialized() -> Data {
        var out = Data(capacity: Self.headerSize + payload.count)
        let length = UInt32(payload.count)
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8(length & 0xFF))
        out.append(rawKind)
        out.append(flags)
        out.appendBE(streamID & 0x7FFF_FFFF)
        out.append(payload)
        return out
    }

    /// Payload length announced by a 9-byte frame header.
    static func payloadLength(header: Data) -> Int {
        let bytes = [UInt8](header)
        return Int(bytes[0]) << 16 | Int(bytes[1]) << 8 | Int(bytes[2])
    }

    static func parse(header: Data, payload: Data) -> HTTP2Frame {
        let bytes = [UInt8](header)
        let stream = (UInt32(bytes[5]) << 24 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 8 | UInt32(bytes[8])) & 0x7FFF_FFFF
        return HTTP2Frame(rawKind: bytes[3], flags: bytes[4], streamID: stream, payload: payload)
    }

    var settingsValues: [UInt16: UInt32] {
        var values: [UInt16: UInt32] = [:]
        let bytes = [UInt8](payload)
        var index = 0
        while index + 6 <= bytes.count {
            let identifier = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
            let value = UInt32(bytes[index + 2]) << 24 | UInt32(bytes[index + 3]) << 16
                | UInt32(bytes[index + 4]) << 8 | UInt32(bytes[index + 5])
            values[identifier] = value
            index += 6
        }
        return values
    }

    var windowIncrement: Int {
        let bytes = [UInt8](payload)
        guard bytes.count >= 4 else { return 0 }
        return Int((UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])) & 0x7FFF_FFFF)
    }
}
