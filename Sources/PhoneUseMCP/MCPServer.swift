import Foundation
import PhoneUseKit

// MCP tool definitions and dispatch, shared by the stdio bridge (`phone-use-mcp`), which answers
// lifecycle and discovery requests itself, and the app, which runs every `tools/call`.
// Messages are newline-delimited JSON-RPC 2.0. Coordinates are iOS points or Android pixels with
// the origin at the top-left, matching the image returned by `get_screen`.

struct ToolFailure: Error {
    let message: String
}

private let deviceProperty: [String: Any] = [
    "type": "string",
    "description": "Device name, UDID or identifier. Defaults to the first connected device.",
]
private let returnScreenProperty: [String: Any] = [
    "type": "boolean",
    "description": "Return a screenshot taken shortly after the action.",
]

private func pointProperty(_ description: String) -> [String: Any] {
    ["type": "number", "description": description]
}

private let toolDefinitions: [[String: Any]] = [
    [
        "name": "list_devices",
        "description": "List iOS and Android devices connected to this Mac, plus iOS simulators booted on it (connection 'simulator'). Only devices whose state is 'ready' can be controlled; the PhoneUse app guides the user through the other states.",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
    ],
    [
        "name": "get_screen",
        "description": "Capture the device screen. The image is scaled to the screen size in points; use the same coordinate space for tap and swipe. To enter text, focus a field and tap the keys of the on-screen keyboard, including the input method's candidate bar.",
        "inputSchema": ["type": "object", "properties": ["device": deviceProperty]],
    ],
    [
        "name": "tap",
        "description": "Tap at a point on the screen.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "x": pointProperty("X in points from the left edge"),
                "y": pointProperty("Y in points from the top edge"),
                "device": deviceProperty,
                "return_screen": returnScreenProperty,
            ],
            "required": ["x", "y"],
        ],
    ],
    [
        "name": "long_press",
        "description": "Touch and hold at a point on the screen.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "x": pointProperty("X in points from the left edge"),
                "y": pointProperty("Y in points from the top edge"),
                "duration_ms": ["type": "integer", "description": "Hold duration, default 800"],
                "device": deviceProperty,
                "return_screen": returnScreenProperty,
            ],
            "required": ["x", "y"],
        ],
    ],
    [
        "name": "swipe",
        "description": "Drag one finger from one point to another. Use it to scroll (drag up to scroll content down). Starting at the very bottom edge and dragging up goes to the home screen; starting at the top edge and dragging down opens Notification Center or Control Center.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "from_x": pointProperty("Start X in points"),
                "from_y": pointProperty("Start Y in points"),
                "to_x": pointProperty("End X in points"),
                "to_y": pointProperty("End Y in points"),
                "duration_ms": ["type": "integer", "description": "Gesture duration, default 300"],
                "device": deviceProperty,
                "return_screen": returnScreenProperty,
            ],
            "required": ["from_x", "from_y", "to_x", "to_y"],
        ],
    ],
    [
        "name": "press_button",
        "description": "Press a device button. back and app_switch are Android-only; siri is iOS-only.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "button": ["type": "string", "enum": HardwareButton.allCases.map(\.rawValue)],
                "device": deviceProperty,
                "return_screen": returnScreenProperty,
            ],
            "required": ["button"],
        ],
    ],
    [
        "name": "launch_app",
        "description": "Launch (or relaunch) an installed app by iOS bundle identifier or Android package name.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "bundle_id": ["type": "string"],
                "device": deviceProperty,
                "return_screen": returnScreenProperty,
            ],
            "required": ["bundle_id"],
        ],
    ],
]

private let toolNames = Set(toolDefinitions.compactMap { $0["name"] as? String })

/// The phone-use MCP server, independent of transport.
public enum MCPServer {
    public static let name = "phone-use"
    public static let version = "0.2.0"

    /// Answers requests that need no device: `initialize`, `ping` and `tools/list`.
    /// Returns nil for notifications and for `tools/call`.
    public static func localReply(to message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            return result(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": name, "version": version],
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": toolDefinitions])
        case "tools/call":
            return nil
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    /// Handles one request, running tools against `DeviceHub.shared` after `prepare` (which the
    /// app uses to make sure its daemon is up). Returns nil for notifications.
    public static func handle(_ message: [String: Any],
                              prepare: @Sendable () async throws -> Void = {}) async -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        guard message["method"] as? String == "tools/call" else { return localReply(to: message) }
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            guard toolNames.contains(name) else { throw ToolFailure(message: "Unknown tool '\(name)'") }
            try await prepare()
            return result(id, ["content": try await callTool(name, arguments)])
        } catch let failure as ToolFailure {
            return toolError(id: id, failure.message)
        } catch {
            return toolError(id: id, guidance(for: error))
        }
    }

    /// Like Xcode's MCP errors, says what the agent should ask the user to do, since setup steps
    /// (connecting, trusting, pairing, Developer Mode) happen on the device and in the app.
    static func guidance(for error: Error) -> String {
        guard let error = error as? DeviceHubError else { return "\(error)" }
        switch error {
        case .deviceNotFound:
            return "\(error). Call list_devices to see what is connected. If the device is missing, ask the user to connect it by USB or put it on the same Wi-Fi as this Mac, then retry."
        case .deviceNotReady:
            return "\(error). Ask the user to open PhoneUse and finish setting up this device there (trust this Mac, pairing, Developer Mode), then retry."
        case .daemonUnavailable(let detail):
            return "PhoneUse could not reach its device service (\(detail)). Ask the user to open PhoneUse and check the message it shows, then retry."
        default:
            return "\(error)"
        }
    }

    /// Handles one encoded line; nil when there is nothing to send back.
    public static func handle(line: Data, prepare: @Sendable () async throws -> Void = {}) async -> Data? {
        guard let message = decode(line), let reply = await handle(message, prepare: prepare) else { return nil }
        return encode(reply)
    }

    /// A `tools/call` result reporting `message` as a tool error, which the agent gets to read.
    public static func toolError(id: Any, _ message: String) -> [String: Any] {
        result(id, ["content": [text(message)], "isError": true])
    }

    public static func decode(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// One JSON message without the trailing newline.
    public static func encode(_ message: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: message)
    }

    private static func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }
}

private func text(_ value: String) -> [String: Any] {
    ["type": "text", "text": value]
}

private func number(_ arguments: [String: Any], _ key: String) throws -> Double {
    if let value = arguments[key] as? Double { return value }
    if let value = arguments[key] as? Int { return Double(value) }
    if let value = arguments[key] as? NSNumber { return value.doubleValue }
    throw ToolFailure(message: "Missing numeric argument '\(key)'")
}

private func screenContent(_ session: DeviceSession) async throws -> [[String: Any]] {
    let image = try await session.screenshot()
    let width = Int(session.display.pointWidth.rounded())
    let height = Int(session.display.pointHeight.rounded())
    guard let scaled = ImageEncoding.resized(image, width: width, height: height),
          let jpeg = ImageEncoding.jpeg(scaled) else {
        throw ToolFailure(message: "Failed to encode screenshot")
    }
    return [
        ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
        text("Screen of \(session.device.name): \(width)x\(height) points, origin at top-left."),
    ]
}

private func callTool(_ name: String, _ arguments: [String: Any]) async throws -> [[String: Any]] {
    let hub = DeviceHub.shared
    let deviceQuery = arguments["device"] as? String

    if name == "list_devices" {
        let devices = try await hub.devices()
        let data = try JSONEncoder().encode(devices)
        return [text(String(decoding: data, as: UTF8.self))]
    }

    let session = try await hub.session(for: deviceQuery)
    let width = session.display.pointWidth
    let height = session.display.pointHeight
    let summary: String

    switch name {
    case "get_screen":
        return try await screenContent(session)
    case "tap":
        let x = try number(arguments, "x"), y = try number(arguments, "y")
        try await session.tap(x: x / width, y: y / height)
        summary = "Tapped (\(x), \(y))."
    case "long_press":
        let x = try number(arguments, "x"), y = try number(arguments, "y")
        let ms = (try? number(arguments, "duration_ms")) ?? 800
        try await session.longPress(x: x / width, y: y / height, duration: .milliseconds(Int(ms)))
        summary = "Long-pressed (\(x), \(y)) for \(Int(ms)) ms."
    case "swipe":
        let fromX = try number(arguments, "from_x"), fromY = try number(arguments, "from_y")
        let toX = try number(arguments, "to_x"), toY = try number(arguments, "to_y")
        let ms = (try? number(arguments, "duration_ms")) ?? 300
        try await session.swipe(fromX: fromX / width, fromY: fromY / height,
                                toX: toX / width, toY: toY / height, duration: .milliseconds(Int(ms)))
        summary = "Swiped from (\(fromX), \(fromY)) to (\(toX), \(toY))."
    case "press_button":
        guard let raw = arguments["button"] as? String, let button = HardwareButton(rawValue: raw) else {
            throw ToolFailure(message: "Unknown button")
        }
        try await session.press(button)
        summary = "Pressed \(raw)."
    case "launch_app":
        guard let bundleID = arguments["bundle_id"] as? String else {
            throw ToolFailure(message: "Missing 'bundle_id'")
        }
        try await session.launchApp(bundleID: bundleID)
        summary = "Launched \(bundleID)."
    default:
        throw ToolFailure(message: "Unknown tool '\(name)'")
    }

    guard arguments["return_screen"] as? Bool == true else { return [text(summary)] }
    try await Task.sleep(for: .milliseconds(600))
    return [text(summary)] + (try await screenContent(session))
}
