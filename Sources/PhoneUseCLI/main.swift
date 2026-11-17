import PhoneUseKit
import Foundation

let usage = """
usage: phone-use [--device <name|udid|android:serial|simulator:udid>] <command>
  list
  pair                             show the Trust prompt on the device
  reveal-developer-mode            make the Developer Mode switch appear in Settings
  mount                            mount the Developer Disk Image
  tap <x> <y>                      normalized 0...1 coordinates
  swipe <x1> <y1> <x2> <y2> [ms]
  longpress <x> <y> [ms]
  press <\(HardwareButton.allCases.map(\.rawValue).joined(separator: "|"))>
  screenshot <file.png>
  launch <bundle-id|package-name>
  bench                            screenshot polling rate
  serve [port]                     local web video preview (default: 8765)

Needs a running phone-use (or a daemon at $DEVICEHUB_SOCKET).
"""

var arguments = Array(CommandLine.arguments.dropFirst())
var deviceQuery: String?
if let index = arguments.firstIndex(of: "--device"), index + 1 < arguments.count {
    deviceQuery = arguments[index + 1]
    arguments.removeSubrange(index...index + 1)
}

@MainActor
func number(_ index: Int) -> Double {
    guard index < arguments.count, let value = Double(arguments[index]) else {
        print(usage)
        exit(2)
    }
    return value
}

@MainActor
func argument(_ index: Int) -> String {
    guard index < arguments.count else {
        print(usage)
        exit(2)
    }
    return arguments[index]
}

@MainActor
func udid(_ hub: DeviceHub) async throws -> String {
    let devices = try await hub.devices()
    if let deviceQuery {
        let needle = deviceQuery.lowercased()
        if let match = devices.first(where: { $0.udid.lowercased() == needle || $0.name.lowercased().contains(needle) }) {
            return match.udid
        }
        throw DeviceHubError.deviceNotFound(deviceQuery)
    }
    guard let first = devices.first(where: \.isAttached) else { throw DeviceHubError.deviceNotFound("<any>") }
    return first.udid
}

@MainActor
func run() async throws {
    guard let command = arguments.first else {
        print(usage)
        exit(2)
    }
    let hub = DeviceHub.shared
    switch command {
    case "serve":
        let value = arguments.count > 1 ? arguments[1] : "8765"
        guard let port = UInt16(value), port > 0, arguments.count <= 2 else {
            throw DeviceHubError.serviceFailed("Usage: phone-use [--device <device>] serve [1...65535]")
        }
        try await serveWebPreview(deviceQuery: deviceQuery, port: port)
    case "list":
        for device in try await hub.devices() {
            print([device.name, device.state.rawValue, device.productType ?? "", device.osDescription ?? "",
                   device.connection, device.udid].joined(separator: "\t"))
        }
    case "pair":
        try await hub.pair(try await udid(hub))
    case "reveal-developer-mode":
        try await hub.revealDeveloperMode(try await udid(hub))
    case "mount":
        try await hub.mountDeveloperImage(try await udid(hub))
    case "tap":
        try await hub.session(for: deviceQuery).tap(x: number(1), y: number(2))
    case "swipe":
        let ms = arguments.count > 5 ? Int(number(5)) : 300
        try await hub.session(for: deviceQuery).swipe(
            fromX: number(1), fromY: number(2), toX: number(3), toY: number(4), duration: .milliseconds(ms))
    case "longpress":
        let ms = arguments.count > 3 ? Int(number(3)) : 800
        try await hub.session(for: deviceQuery).longPress(x: number(1), y: number(2), duration: .milliseconds(ms))
    case "press":
        guard let button = HardwareButton(rawValue: argument(1)) else {
            print(usage)
            exit(2)
        }
        try await hub.session(for: deviceQuery).press(button)
    case "screenshot":
        let path = argument(1)
        let session = try await hub.session(for: deviceQuery)
        let start = Date()
        let image = try await session.screenshot()
        let elapsed = Date().timeIntervalSince(start)
        guard let png = ImageEncoding.png(image) else { throw DeviceHubError.serviceFailed("PNG encoding failed") }
        try png.write(to: URL(fileURLWithPath: path))
        print("saved \(image.width)x\(image.height) in \(String(format: "%.0f", elapsed * 1000)) ms")
    case "bench":
        let session = try await hub.session(for: deviceQuery)
        let start = Date()
        var frames = 0
        while Date().timeIntervalSince(start) < 5 {
            _ = try await session.screenshot()
            frames += 1
        }
        print("screenshots: \(String(format: "%.1f", Double(frames) / Date().timeIntervalSince(start))) fps")
    case "launch":
        try await hub.session(for: deviceQuery).launchApp(bundleID: argument(1))
    default:
        print(usage)
        exit(2)
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
