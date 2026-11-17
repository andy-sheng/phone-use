import CryptoKit
import Foundation

/// Small, bounded RFC 6455 subset: binary video out, keyframe requests and control frames in.
enum WebSocketVideo {
    static func handshake(_ request: WebPreviewHTTP.Request, token: String) -> Data? {
        guard request.method == "GET", request.path == "/video?token=\(token)",
              request.headers["origin"] == "http://" + (request.headers["host"] ?? ""),
              request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
              request.headers["sec-websocket-version"] == "13",
              let key = request.headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else { return nil }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        return Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8)
    }

    static func frame(_ payload: Data, opcode: UInt8 = 2) -> Data {
        var data = Data([0x80 | opcode])
        if payload.count < 126 { data.append(UInt8(payload.count)) }
        else if payload.count <= 65535 { data.append(126); append(UInt64(payload.count), bytes: 2, to: &data) }
        else { data.append(127); append(UInt64(payload.count), bytes: 8, to: &data) }
        data.append(payload)
        return data
    }

    static func append(_ value: UInt64, bytes: Int, to data: inout Data) {
        for shift in (0..<bytes).reversed() { data.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) }
    }

    struct Message { let opcode: UInt8; let payload: Data }
    static func read(_ buffer: inout Data) throws -> Message? {
        guard buffer.count <= 8192 else { throw WebPreviewHTTP.InvalidRequest.malformed }
        let bytes = [UInt8](buffer)
        guard bytes.count >= 2 else { return nil }
        let opcode = bytes[0] & 15
        guard bytes[0] & 0xf0 == 0x80, [1, 8, 9, 10].contains(opcode), bytes[1] & 0x80 != 0 else { throw WebPreviewHTTP.InvalidRequest.malformed }
        var count = Int(bytes[1] & 127), offset = 2
        if count == 126 {
            guard bytes.count >= 4 else { return nil }
            count = Int(bytes[2]) * 256 + Int(bytes[3]); offset = 4
            guard count >= 126 else { throw WebPreviewHTTP.InvalidRequest.malformed }
        } else if count == 127 { throw WebPreviewHTTP.InvalidRequest.malformed }
        guard count <= 4096, opcode < 8 || count <= 125, opcode != 8 || count != 1 else { throw WebPreviewHTTP.InvalidRequest.malformed }
        guard bytes.count >= offset + 4 + count else { return nil }
        let mask = Array(bytes[offset..<offset + 4]); offset += 4
        let payload = Data((0..<count).map { bytes[offset + $0] ^ mask[$0 % 4] })
        buffer = Data(bytes.dropFirst(offset + count))
        return Message(opcode: opcode, payload: payload)
    }
}
