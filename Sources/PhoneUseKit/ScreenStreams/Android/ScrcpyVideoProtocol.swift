import Foundation

enum ScrcpyVideoError: Error, CustomStringConvertible {
    case malformed(String)
    case unsupportedCodec
    case geometryChanged
    case decoder(String)

    var description: String {
        switch self {
        case .malformed(let detail): "Malformed Android video stream: \(detail)"
        case .unsupportedCodec: "Android video did not negotiate H.264"
        case .geometryChanged: "Android screen orientation or aspect ratio changed; reconnect before sending input"
        case .decoder(let detail): "Android video decoder failed: \(detail)"
        }
    }
}

struct ScrcpyVideoMetadata: Equatable {
    let width: Int
    let height: Int

    init(_ data: Data) throws {
        guard data.count == 12 else { throw ScrcpyVideoError.malformed("codec header must contain 12 bytes") }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == Array("h264".utf8) else { throw ScrcpyVideoError.unsupportedCodec }
        width = Int(bytes[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        height = Int(bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard (1...16_384).contains(width), (1...16_384).contains(height) else {
            throw ScrcpyVideoError.malformed("invalid encoded dimensions")
        }
    }
}

struct ScrcpyPacketHeader: Equatable {
    static let maximumPayloadSize = 16 * 1024 * 1024
    let isConfiguration: Bool
    let isKeyframe: Bool
    let presentationTime: UInt64
    let payloadSize: Int

    init(_ data: Data) throws {
        guard data.count == 12 else { throw ScrcpyVideoError.malformed("packet header must contain 12 bytes") }
        let bytes = [UInt8](data)
        let flags = bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        isConfiguration = flags & (1 << 63) != 0
        isKeyframe = flags & (1 << 62) != 0
        presentationTime = flags & ((1 << 62) - 1)
        payloadSize = Int(bytes[8..<12].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        guard (1...Self.maximumPayloadSize).contains(payloadSize) else {
            throw ScrcpyVideoError.malformed("packet length is outside the allowed range")
        }
    }
}

enum AndroidVideoGeometry {
    /// scrcpy preserves aspect ratio, rounding each scaled dimension to the encoder's alignment.
    /// Permit an eight-pixel alignment error on either axis, but reject rotation/stretching.
    static func validate(width: Int, height: Int, display: DisplayInfo) throws {
        guard width > 0, height > 0, display.pixelWidth.isFinite, display.pixelHeight.isFinite,
              display.pixelWidth > 0, display.pixelHeight > 0 else {
            throw ScrcpyVideoError.malformed("invalid display dimensions")
        }
        let error = abs(Double(width) * display.pixelHeight - Double(height) * display.pixelWidth)
        guard error <= 8 * (display.pixelWidth + display.pixelHeight) else {
            throw ScrcpyVideoError.geometryChanged
        }
    }
}

enum H264AnnexB {
    static func nalUnits(_ data: Data) throws -> [Data] {
        guard !data.isEmpty, data.count <= ScrcpyPacketHeader.maximumPayloadSize else {
            throw ScrcpyVideoError.malformed("invalid H.264 payload length")
        }
        let bytes = [UInt8](data)
        var starts: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 {
                    starts.append((index, 3)); index += 3; continue
                }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, 4)); index += 4; continue
                }
            }
            index += 1
        }
        guard let first = starts.first, bytes[..<first.offset].allSatisfy({ $0 == 0 }) else {
            throw ScrcpyVideoError.malformed("H.264 Annex B start code is missing")
        }
        var result: [Data] = []
        for (number, start) in starts.enumerated() {
            let begin = start.offset + start.length
            var end = number + 1 < starts.count ? starts[number + 1].offset : bytes.count
            while end > begin, bytes[end - 1] == 0 { end -= 1 }
            guard begin < end, bytes[begin] & 0x80 == 0, (1...23).contains(bytes[begin] & 0x1F) else {
                throw ScrcpyVideoError.malformed("invalid or empty H.264 NAL unit")
            }
            result.append(Data(bytes[begin..<end]))
        }
        return result
    }

    static func avcc(_ units: [Data]) -> Data {
        var payload = Data()
        for unit in units {
            payload.appendBE(UInt32(unit.count))
            payload.append(unit)
        }
        return payload
    }
}
