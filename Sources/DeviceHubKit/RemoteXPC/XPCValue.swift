import Foundation

/// A value in an XPC message as it travels over RemoteXPC.
public indirect enum XPCValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int64(Int64)
    case uint64(UInt64)
    case double(Double)
    /// Nanoseconds since 1970.
    case date(Int64)
    case data(Data)
    case string(String)
    case uuid(UUID)
    case array([XPCValue])
    case dictionary(XPCDictionary)

    public subscript(key: String) -> XPCValue? {
        if case .dictionary(let dictionary) = self { return dictionary[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var dataValue: Data? {
        if case .data(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let value): value
        case .int64(let value): Double(value)
        case .uint64(let value): Double(value)
        default: nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int64(let value): Int(value)
        case .uint64(let value): Int(value)
        case .double(let value): Int(value)
        default: nil
        }
    }

    public var arrayValue: [XPCValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var dictionaryValue: XPCDictionary? {
        if case .dictionary(let value) = self { return value }
        return nil
    }
}

extension XPCValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: XPCValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, XPCValue)...) { self = .dictionary(XPCDictionary(elements)) }
    public init(nilLiteral: ()) { self = .null }
}

/// An XPC dictionary. Keys keep their insertion order, which is also their wire order.
public struct XPCDictionary: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    public struct Entry: Sendable, Equatable {
        public let key: String
        public var value: XPCValue
    }

    public private(set) var entries: [Entry]

    public init(_ pairs: [(String, XPCValue)] = []) {
        entries = pairs.map { Entry(key: $0.0, value: $0.1) }
    }

    public init(dictionaryLiteral elements: (String, XPCValue)...) {
        self.init(elements)
    }

    public var isEmpty: Bool { entries.isEmpty }

    public subscript(key: String) -> XPCValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            if let index = entries.firstIndex(where: { $0.key == key }) {
                if let newValue { entries[index].value = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append(Entry(key: key, value: newValue))
            }
        }
    }
}
