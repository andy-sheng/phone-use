import Foundation

/// The RemoteXPC message frame (`XpcWrapper`) and the XPC object encoding inside it.
/// Integers are little-endian; strings, data and dictionary keys are padded to 4 bytes,
/// counted from where each value starts.
enum XPCCodec {
    static let wrapperMagic: UInt32 = 0x29B0_0B92
    static let payloadMagic: UInt32 = 0x4213_3742
    static let payloadVersion: UInt32 = 5
    static let wrapperHeaderSize = 24

    struct Flags: OptionSet, Sendable {
        let rawValue: UInt32
        static let alwaysSet = Flags(rawValue: 0x0000_0001)
        static let dataPresent = Flags(rawValue: 0x0000_0100)
        static let wantingReply = Flags(rawValue: 0x0001_0000)
        static let reply = Flags(rawValue: 0x0002_0000)
        static let initHandshake = Flags(rawValue: 0x0040_0000)
    }

    struct Wrapper {
        var flags: UInt32
        var messageID: UInt64
        var payload: XPCValue?
    }

    enum Tag: UInt32 {
        case null = 0x1000
        case bool = 0x2000
        case int64 = 0x3000
        case uint64 = 0x4000
        case double = 0x5000
        case date = 0x7000
        case data = 0x8000
        case string = 0x9000
        case uuid = 0xA000
        case fd = 0xB000
        case array = 0xE000
        case dictionary = 0xF000
    }

    struct DecodingError: Error, CustomStringConvertible {
        let description: String
    }

    // MARK: Encoding

    static func encodeWrapper(_ wrapper: Wrapper) -> Data {
        var body = Data()
        if let payload = wrapper.payload {
            body.appendLE(payloadMagic)
            body.appendLE(payloadVersion)
            encode(payload, into: &body)
        }
        var frame = Data(capacity: wrapperHeaderSize + body.count)
        frame.appendLE(wrapperMagic)
        frame.appendLE(wrapper.flags)
        frame.appendLE(UInt64(body.count))
        frame.appendLE(wrapper.messageID)
        frame.append(body)
        return frame
    }

    static func encode(_ value: XPCValue, into out: inout Data) {
        switch value {
        case .null:
            out.appendLE(Tag.null.rawValue)
        case .bool(let flag):
            out.appendLE(Tag.bool.rawValue)
            out.appendLE(UInt32(flag ? 1 : 0))
        case .int64(let number):
            out.appendLE(Tag.int64.rawValue)
            out.appendLE(UInt64(bitPattern: number))
        case .uint64(let number):
            out.appendLE(Tag.uint64.rawValue)
            out.appendLE(number)
        case .double(let number):
            out.appendLE(Tag.double.rawValue)
            out.appendLE(number.bitPattern)
        case .date(let nanoseconds):
            out.appendLE(Tag.date.rawValue)
            out.appendLE(UInt64(bitPattern: nanoseconds))
        case .data(let bytes):
            out.appendLE(Tag.data.rawValue)
            out.appendLE(UInt32(bytes.count))
            out.append(bytes)
            out.appendPadding(for: bytes.count)
        case .string(let text):
            out.appendLE(Tag.string.rawValue)
            let bytes = Array(text.utf8) + [0]
            out.appendLE(UInt32(bytes.count))
            out.append(contentsOf: bytes)
            out.appendPadding(for: bytes.count)
        case .uuid(let uuid):
            out.appendLE(Tag.uuid.rawValue)
            withUnsafeBytes(of: uuid.uuid) { out.append(contentsOf: $0) }
        case .array(let items):
            out.appendLE(Tag.array.rawValue)
            var body = Data()
            body.appendLE(UInt32(items.count))
            for item in items { encode(item, into: &body) }
            out.appendLE(UInt32(body.count))
            out.append(body)
        case .dictionary(let dictionary):
            out.appendLE(Tag.dictionary.rawValue)
            var body = Data()
            body.appendLE(UInt32(dictionary.entries.count))
            for entry in dictionary.entries {
                let key = Array(entry.key.utf8) + [0]
                body.append(contentsOf: key)
                body.appendPadding(for: key.count)
                encode(entry.value, into: &body)
            }
            out.appendLE(UInt32(body.count))
            out.append(body)
        }
    }

    // MARK: Decoding

    /// Parses one wrapper from the start of `data`. Returns `nil` when `data` holds only part of it.
    static func decodeWrapper(_ data: Data) throws -> (wrapper: Wrapper, length: Int)? {
        guard data.count >= wrapperHeaderSize else { return nil }
        var reader = ByteReader(data)
        guard try reader.u32() == wrapperMagic else { throw DecodingError(description: "bad wrapper magic") }
        let flags = try reader.u32()
        let size = Int(try reader.u64())
        let messageID = try reader.u64()
        guard data.count >= wrapperHeaderSize + size else { return nil }
        var payload: XPCValue?
        if size >= 8 {
            var body = ByteReader(data.subdata(in: data.startIndex + wrapperHeaderSize ..< data.startIndex + wrapperHeaderSize + size))
            if try body.u32() == payloadMagic, try body.u32() == payloadVersion {
                payload = try decodeValue(&body)
            }
        }
        return (Wrapper(flags: flags, messageID: messageID, payload: payload), wrapperHeaderSize + size)
    }

    static func decodeValue(_ reader: inout ByteReader) throws -> XPCValue {
        let rawTag = try reader.u32()
        guard let tag = Tag(rawValue: rawTag) else {
            throw DecodingError(description: String(format: "unsupported XPC type 0x%x", rawTag))
        }
        switch tag {
        case .null:
            return .null
        case .bool:
            return .bool(try reader.u32() != 0)
        case .int64:
            return .int64(Int64(bitPattern: try reader.u64()))
        case .uint64:
            return .uint64(try reader.u64())
        case .double:
            return .double(Double(bitPattern: try reader.u64()))
        case .date:
            return .date(Int64(bitPattern: try reader.u64()))
        case .fd:
            return .uint64(UInt64(try reader.u32()))
        case .data:
            let length = Int(try reader.u32())
            let bytes = try reader.bytes(length)
            try reader.skipPadding(for: length)
            return .data(bytes)
        case .string:
            let length = Int(try reader.u32())
            var bytes = try reader.bytes(length)
            try reader.skipPadding(for: length)
            while bytes.last == 0 { bytes.removeLast() }
            return .string(String(decoding: bytes, as: UTF8.self))
        case .uuid:
            let bytes = try reader.bytes(16)
            let uuid = bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
            return .uuid(uuid)
        case .array:
            _ = try reader.u32()
            let count = Int(try reader.u32())
            var items: [XPCValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count { items.append(try decodeValue(&reader)) }
            return .array(items)
        case .dictionary:
            _ = try reader.u32()
            let count = Int(try reader.u32())
            var pairs: [(String, XPCValue)] = []
            pairs.reserveCapacity(count)
            for _ in 0..<count {
                let key = try reader.cString()
                pairs.append((key, try decodeValue(&reader)))
            }
            return .dictionary(XPCDictionary(pairs))
        }
    }
}

struct ByteReader {
    private let data: Data
    private(set) var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw XPCCodec.DecodingError(description: "truncated XPC object") }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func u32() throws -> UInt32 {
        try bytes(4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
    }

    mutating func u64() throws -> UInt64 {
        try bytes(8).withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
    }

    mutating func skipPadding(for length: Int) throws {
        _ = try bytes((4 - length % 4) % 4)
    }

    mutating func cString() throws -> String {
        guard let end = data[offset...].firstIndex(of: 0) else {
            throw XPCCodec.DecodingError(description: "unterminated XPC string")
        }
        let length = end - offset + 1
        let text = String(decoding: data[offset ..< end], as: UTF8.self)
        offset += length
        try skipPadding(for: length)
        return text
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendPadding(for length: Int) {
        append(contentsOf: [UInt8](repeating: 0, count: (4 - length % 4) % 4))
    }
}
