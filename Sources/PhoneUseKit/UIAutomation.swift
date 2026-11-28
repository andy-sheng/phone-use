import Foundation

/// A fresh accessibility match. Exactly one primary selector is required; type narrows it.
public struct UISelector: Sendable {
    public let id: String?
    public let label: String?
    public let labelContains: String?
    public let elementType: String?

    public init(id: String? = nil, label: String? = nil, labelContains: String? = nil, elementType: String? = nil) throws {
        guard [id, label, labelContains].compactMap({ $0 }).count == 1,
              [id, label, labelContains, elementType].compactMap({ $0 }).allSatisfy({ !$0.isEmpty }) else {
            throw DeviceHubError.serviceFailed("Specify exactly one non-empty id, label or label_contains; element_type is an optional filter")
        }
        self.id = id; self.label = label; self.labelContains = labelContains; self.elementType = elementType
    }

    func matches(_ element: UIElement) -> Bool {
        (id == nil || element.id == id) && (label == nil || element.label == label)
            && (labelContains == nil || element.label?.contains(labelContains!) == true)
            && (elementType == nil || element.type == elementType)
    }

    /// Shared by live lookup and offline tests. Never pick the first of several matches.
    func index(in elements: [UIElement]) throws -> Int {
        let matches = elements.indices.filter { self.matches(elements[$0]) }
        guard matches.count == 1 else {
            let candidates = (matches.isEmpty ? Array(elements.indices) : matches).prefix(8).map {
                "\(elements[$0].type) label=\(elements[$0].label ?? "") id=\(elements[$0].id ?? "")"
            }.joined(separator: "; ")
            throw DeviceHubError.serviceFailed("\(matches.isEmpty ? "No element matches" : "Multiple elements match") the selector. Run describe_ui and refine id/label/element_type. Candidates: \(candidates)")
        }
        guard elements[matches[0]].enabled != false else { throw DeviceHubError.serviceFailed("The matching element is disabled") }
        return matches[0]
    }
}

public struct UIElement: Codable, Sendable {
    public struct Frame: Codable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }
    public let type: String
    public let id: String?
    public let label: String?
    public let value: String?
    /// nil means the platform did not report enabled state.
    public let enabled: Bool?
    /// Physical AX Audit supplies no geometry; never substitute a zero rectangle.
    public let frame: Frame?
    public let depth: Int
}

public struct UITree: Codable, Sendable {
    public let elements: [UIElement]
    public let truncated: Bool
    /// Android frames use display pixels, simulator frames use UI points, and physical iOS omits geometry.
    public let coordinateSpace: String

    public var outline: String {
        elements.map { element in
            let label = element.label.map { " \(String(reflecting: String($0.prefix(120))))" } ?? ""
            let id = element.id.map { " id=\(String(reflecting: $0))" } ?? ""
            // Secure field values must never be included in either output format.
            let value = element.value.map { " value=\(String(reflecting: String($0.prefix(120))))" } ?? ""
            let frame = element.frame.map { " frame=(\($0.x),\($0.y),\($0.width),\($0.height))" } ?? ""
            return "\(String(repeating: "  ", count: element.depth))\(element.type)\(label)\(id)\(value)\(element.enabled == false ? " disabled" : "")\(frame)"
        }.joined(separator: "\n") + (truncated ? "\n[Tree truncated; use stable selectors or screenshot for missing controls.]" : "")
    }
}

/// A complete press and release on the device's US keyboard, expressed as a USB HID usage.
public struct DeviceKeystroke: Encodable, Equatable, Sendable {
    let code: UInt32
    let shift: Bool

    public enum EditingKey: UInt32, Sendable {
        case enter = 40, escape, backspace, tab
        case home = 74, pageUp, forwardDelete, end, pageDown, right, left, down, up
    }

    init(code: UInt32, shift: Bool) {
        self.code = code
        self.shift = shift
    }

    public init(_ key: EditingKey, shift: Bool = false) {
        self.init(code: key.rawValue, shift: shift)
    }

    private static let plain = Array("1234567890-=[]\\;'`,./")
    private static let shifted = Array("!@#$%^&*()_+{}|:\"~<>?")
    private static let codes: [UInt32] = [30,31,32,33,34,35,36,37,38,39,45,46,47,48,49,51,52,53,54,55,56]

    public init?(character: Character) {
        if let scalar = character.asciiValue, (97...122).contains(scalar) {
            self.init(code: UInt32(scalar - 97 + 4), shift: false)
        } else if let scalar = character.asciiValue, (65...90).contains(scalar) {
            self.init(code: UInt32(scalar - 65 + 4), shift: true)
        } else if let index = Self.plain.firstIndex(of: character) {
            self.init(code: Self.codes[index], shift: false)
        } else if let index = Self.shifted.firstIndex(of: character) {
            self.init(code: Self.codes[index], shift: true)
        } else {
            switch character {
            case " ": self.init(code: 44, shift: false)
            case "\n": self.init(.enter)
            case "\t": self.init(.tab)
            default: return nil
            }
        }
    }
}

/// Validate the entire string before focusing the target field.
enum SimulatorKeyboard {
    static func keys(for text: String) throws -> [DeviceKeystroke] {
        guard text.count <= 10000 else { throw DeviceHubError.serviceFailed("Text is limited to 10000 characters per call") }
        return try text.map { character in
            guard let key = DeviceKeystroke(character: character) else {
                throw DeviceHubError.capabilityUnavailable("Text contains characters unsupported by HID typing. Use US keyboard characters, or enter Unicode using the on-screen input method. No text was sent")
            }
            return key
        }
    }
}
