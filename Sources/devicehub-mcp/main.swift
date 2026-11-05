import DeviceHubKit
import Foundation

// Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0).
// Coordinates are iOS points or Android pixels, with the origin at the top-left,
// matching the image returned by `get_screen`.

struct ToolFailure: Error {
    let message: String
}

let deviceProperty: [String: Any] = [
    "type": "string",
    "description": "Device name, UDID or identifier. Defaults to the first connected device.",
]
let returnScreenProperty: [String: Any] = [
    "type": "boolean",
    "description": "Return a screenshot taken shortly after the action.",
]

func pointProperty(_ description: String) -> [String: Any] {
    ["type": "number", "description": description]
}

let tools: [[String: Any]] = [
    [
        "name": "list_devices",
        "description": "List iOS and Android devices connected to this Mac. Only devices whose state is 'ready' can be controlled; the phone-use app guides the user through the other states.",
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

func text(_ value: String) -> [String: Any] {
    ["type": "text", "text": value]
}

func number(_ arguments: [String: Any], _ key: String) throws -> Double {
    if let value = arguments[key] as? Double { return value }
    if let value = arguments[key] as? Int { return Double(value) }
    if let value = arguments[key] as? NSNumber { return value.doubleValue }
    throw ToolFailure(message: "Missing numeric argument '\(key)'")
}

func screenContent(_ session: DeviceSession) async throws -> [[String: Any]] {
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

func callTool(_ name: String, _ arguments: [String: Any]) async throws -> [[String: Any]] {
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

@MainActor
func handle(_ message: [String: Any]) async -> [String: Any]? {
    guard let method = message["method"] as? String else { return nil }
    guard let id = message["id"] else { return nil }
    let params = message["params"] as? [String: Any] ?? [:]

    func reply(_ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    switch method {
    case "initialize":
        return reply([
            "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "phone-use", "version": "0.1.0"],
        ])
    case "ping":
        return reply([:])
    case "tools/list":
        return reply(["tools": tools])
    case "tools/call":
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        do {
            return reply(["content": try await callTool(name, arguments)])
        } catch let failure as ToolFailure {
            return reply(["content": [text(failure.message)], "isError": true])
        } catch {
            return reply(["content": [text("\(error)")], "isError": true])
        }
    default:
        return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
    }
}

func write(_ response: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

for try await line in FileHandle.standardInput.bytes.lines {
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    if let response = await handle(message) {
        write(response)
    }
}
