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
    /// Simulator AX frames are visual UI points; physical AX Audit uses "unavailable".
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

/// US keyboard HID usages, matching sim-use `type`. Validate the entire string before focusing.
enum SimulatorKeyboard {
    struct Key: Equatable { let code: UInt32; let shift: Bool }

    static func keys(for text: String) throws -> [Key] {
        guard text.count <= 10000 else { throw DeviceHubError.serviceFailed("Text is limited to 10000 characters per call") }
        let plain = Array("1234567890-=[]\\;'`,./")
        let shifted = Array("!@#$%^&*()_+{}|:\"~<>?")
        let codes: [UInt32] = [30,31,32,33,34,35,36,37,38,39,45,46,47,48,49,51,52,53,54,55,56]
        return try text.map { char in
            if let scalar = char.asciiValue, (97...122).contains(scalar) { return Key(code: UInt32(scalar - 97 + 4), shift: false) }
            if let scalar = char.asciiValue, (65...90).contains(scalar) { return Key(code: UInt32(scalar - 65 + 4), shift: true) }
            if let index = plain.firstIndex(of: char) { return Key(code: codes[index], shift: false) }
            if let index = shifted.firstIndex(of: char) { return Key(code: codes[index], shift: true) }
            if let code: UInt32 = [" ": 44, "\n": 40, "\t": 43][String(char)] { return Key(code: code, shift: false) }
            throw DeviceHubError.capabilityUnavailable("Text contains characters unsupported by HID typing. Use US keyboard characters, or enter Unicode using the on-screen input method. No text was sent")
        }
    }
}
