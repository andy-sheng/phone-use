import CoreFoundation
import Foundation
import PhoneUseKit

struct ToolFailure: Error {
    let message: String
}

enum MCPGesture: String, CaseIterable {
    case scrollUp = "scroll-up", scrollDown = "scroll-down"
    case scrollLeft = "scroll-left", scrollRight = "scroll-right"
    case leftEdge = "swipe-from-left-edge", rightEdge = "swipe-from-right-edge"
    case topEdge = "swipe-from-top-edge", bottomEdge = "swipe-from-bottom-edge"

    var isScroll: Bool { rawValue.hasPrefix("scroll-") }

    /// Normalized, native-framebuffer single-finger strokes. No assumed phone resolution.
    var stroke: (fromX: Double, fromY: Double, toX: Double, toY: Double) {
        switch self {
        case .scrollUp: (0.5, 0.8, 0.5, 0.2)
        case .scrollDown: (0.5, 0.2, 0.5, 0.8)
        case .scrollLeft: (0.8, 0.5, 0.2, 0.5)
        case .scrollRight: (0.2, 0.5, 0.8, 0.5)
        case .leftEdge: (0, 0.5, 0.7, 0.5)
        case .rightEdge: (1, 0.5, 0.3, 0.5)
        case .topEdge: (0.5, 0, 0.5, 0.7)
        case .bottomEdge: (0.5, 1, 0.5, 0.3)
        }
    }
}

/// Decode once before opening a device. Invalid input must never turn into a default action.
struct MCPCommand {
    enum Action {
        case listDevices, selectDevice, connectDevice, unlockDevice, screenshot
        case listSimulatorOptions, createSimulator(name: String?, deviceType: String, runtime: String)
        case management(MCPManagement, name: String?, directory: URL?)
        case settings(MCPSettingsCommand)
        case geometry(SimulatorGeometryChange)
        case touchPath([CGPoint], Duration)
        case startRecording, stopRecording(UUID)
        case webPreview(UInt16)
        case describeUI(json: Bool)
        case activate(UISelector)
        case typeText(String, UISelector?)
        case tap(Double, Double, Duration?)
        case longPress(Double, Double, Duration)
        case swipe(Double, Double, Double, Double, Duration)
        case gesture(MCPGesture, Duration)
        case button(HardwareButton, Duration?)
        case launchApp(String)
        case installApp(URL)
        case listApps(String?)
        case listSandboxFiles(bundleID: String, path: String, offset: Int, limit: Int)
        case readSandboxFile(bundleID: String, path: String)
        case downloadSandboxFile(bundleID: String, path: String, destination: URL)
    }

    let action: Action
    let device: String?
    let preDelay: Duration
    let postDelay: Duration
    let returnScreen: Bool

    init(name: String, arguments: [String: Any]) throws {
        let name = MCPToolCatalog.aliases[name] ?? name
        guard let definition = MCPToolCatalog.definitions.first(where: { $0["name"] as? String == name }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else {
            throw ToolFailure(message: "Unknown tool '\(name)'. Call tools/list for supported operations.")
        }
        let unknown = Set(arguments.keys).subtracting(properties.keys)
        guard unknown.isEmpty else {
            throw ToolFailure(message: "Unsupported arguments: \(unknown.sorted().joined(separator: ", ")). Call tools/list for this tool's schema.")
        }
        device = try Self.string(arguments, "device", optional: true)
        preDelay = .seconds(try Self.optionalNumber(arguments, "pre_delay", range: 0...10) ?? 0)
        postDelay = .seconds(try Self.optionalNumber(arguments, "post_delay", range: 0...10) ?? 0)
        if let value = arguments["return_screen"] {
            guard let boolean = value as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
                throw ToolFailure(message: "'return_screen' must be a boolean.")
            }
            returnScreen = boolean.boolValue
        } else { returnScreen = false }

        func point(_ key: String) throws -> Double {
            let number = try Self.number(arguments, key)
            guard number >= 0 else { throw ToolFailure(message: "'\(key)' must be non-negative.") }
            return number
        }
        func duration(default value: Double? = nil) throws -> Duration? {
            guard arguments["duration"] == nil || arguments["duration_ms"] == nil else {
                throw ToolFailure(message: "Use duration (seconds) or duration_ms (legacy milliseconds), not both.")
            }
            if arguments["duration_ms"] != nil {
                let ms = try Self.number(arguments, "duration_ms")
                guard ms.rounded() == ms, (1...10000).contains(ms) else {
                    throw ToolFailure(message: "'duration_ms' must be an integer from 1 to 10000.")
                }
                return .seconds(ms / 1000)
            }
            if let seconds = try Self.optionalNumber(arguments, "duration", range: 0...10) {
                guard seconds > 0 else { throw ToolFailure(message: "'duration' must be greater than 0 seconds.") }
                return .seconds(seconds)
            }
            return value.map { .seconds($0) }
        }
        func target() throws -> UISelector? {
            let id = try Self.string(arguments, "id", optional: true)
            let label = try Self.string(arguments, "label", optional: true)
            let contains = try Self.string(arguments, "label_contains", optional: true)
            let type = try Self.string(arguments, "element_type", optional: true)
            if [id, label, contains, type].allSatisfy({ $0 == nil }) { return nil }
            return try UISelector(id: id, label: label, labelContains: contains, elementType: type)
        }
        if let management = MCPManagement(rawValue: name) {
            guard !management.needsIdentifier || device != nil else { throw ToolFailure(message: "An explicit device identifier is required.") }
            let newName = management == .rename ? try Self.string(arguments, "name") : nil
            var directory: URL?
            if management == .sysdiagnose {
                let path = try Self.string(arguments, "directory")!
                guard path.hasPrefix("/") else { throw ToolFailure(message: "Use an absolute output directory on the Mac.") }
                directory = URL(fileURLWithPath: path, isDirectory: true)
            }
            action = .management(management, name: newName, directory: directory)
            return
        }
        switch name {
        case "unlock_device": action = .unlockDevice
        case "list_simulator_options": action = .listSimulatorOptions
        case "create_simulator":
            action = .createSimulator(name: try Self.string(arguments, "name", optional: true),
                                      deviceType: try Self.string(arguments, "device_type")!,
                                      runtime: try Self.string(arguments, "runtime")!)
        case "get_device_settings", "set_appearance", "set_audio", "set_location":
            action = .settings(try MCPSettingsCommand(name, arguments))
        case "rotate_simulator":
            guard let direction = DeviceRotationDirection(rawValue: try Self.string(arguments, "direction")!) else {
                throw ToolFailure(message: "direction must be left or right.")
            }
            action = .geometry(.rotation(direction))
        case "set_simulator_posture":
            guard let posture = SimulatorPosture(rawValue: try Self.string(arguments, "posture")!) else {
                throw ToolFailure(message: "Unsupported simulator posture.")
            }
            action = .geometry(.posture(posture))
        case "touch_path":
            guard let points = arguments["points"] as? [[String: Any]], (2...256).contains(points.count) else {
                throw ToolFailure(message: "Supply 2 to 256 ordered points.")
            }
            let path = try points.map { point in
                guard Set(point.keys) == ["x", "y"] else { throw ToolFailure(message: "Each point requires exactly x and y.") }
                let x = try Self.number(point, "x"), y = try Self.number(point, "y")
                guard x >= 0 && y >= 0 else { throw ToolFailure(message: "Path coordinates must be non-negative.") }
                return CGPoint(x: x, y: y)
            }
            action = .touchPath(path, try duration(default: 0.5)!)
        case "get_web_preview":
            let port = try Self.optionalNumber(arguments, "port", range: 1...65535) ?? 8765
            guard port.rounded() == port else { throw ToolFailure(message: "'port' must be an integer from 1 to 65535.") }
            action = .webPreview(UInt16(port))
        case "list_apps": action = .listApps(try Self.string(arguments, "search", optional: true))
        case "list_sandbox_files", "read_sandbox_file", "download_sandbox_file":
            let bundle = try Self.string(arguments, "bundle_id")!
            guard !bundle.contains("\0") else { throw ToolFailure(message: "Invalid bundle_id.") }
            let path = try DeviceFiles.relativePath(Self.string(arguments, "path", optional: name == "list_sandbox_files") ?? ".")
            if name == "list_sandbox_files" {
                func integer(_ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
                    guard arguments[key] != nil else { return value }
                    let number = try Self.number(arguments, key)
                    guard number.rounded() == number, Double(range.lowerBound)...Double(range.upperBound) ~= number else {
                        throw ToolFailure(message: "'\(key)' must be an integer in \(range).")
                    }
                    return Int(number)
                }
                action = .listSandboxFiles(bundleID: bundle, path: path,
                                           offset: try integer("offset", default: 0, range: 0...1_000_000),
                                           limit: try integer("limit", default: 200, range: 1...500))
            } else {
                guard path != "." else { throw ToolFailure(message: "Select a file, not the sandbox root.") }
                if name == "read_sandbox_file" { action = .readSandboxFile(bundleID: bundle, path: path) }
                else {
                    let destination = try Self.string(arguments, "destination")!
                    guard destination.hasPrefix("/"), !destination.contains("\0"), !destination.hasSuffix("/") else {
                        throw ToolFailure(message: "'destination' must be an absolute local file path, including a filename.")
                    }
                    action = .downloadSandboxFile(bundleID: bundle, path: path, destination: URL(fileURLWithPath: destination))
                }
            }
        case "list_devices": action = .listDevices
        case "select_device":
            guard device != nil else { throw ToolFailure(message: "select_device requires a device identifier or name.") }
            action = .selectDevice
        case "connect_device": action = .connectDevice
        case "start_recording": action = .startRecording
        case "stop_recording":
            guard let id = UUID(uuidString: try Self.string(arguments, "recording_id")!) else {
                throw ToolFailure(message: "'recording_id' must be the UUID returned by start_recording.")
            }
            action = .stopRecording(id)
        case "screenshot": action = .screenshot
        case "describe_ui":
            let format = try Self.string(arguments, "format", optional: true) ?? "outline"
            guard ["outline", "json"].contains(format) else { throw ToolFailure(message: "'format' must be outline or json.") }
            action = .describeUI(json: format == "json")
        case "tap":
            if let selector = try target() {
                guard arguments["x"] == nil, arguments["y"] == nil, arguments["duration"] == nil else {
                    throw ToolFailure(message: "Selectors cannot be combined with coordinates or duration. Use a coordinate tap for timed holds.")
                }
                action = .activate(selector)
            } else { action = .tap(try point("x"), try point("y"), try duration()) }
        case "long_press": action = .longPress(try point("x"), try point("y"), try duration(default: 0.8)!)
        case "swipe":
            let canonical = ["start_x", "start_y", "end_x", "end_y"]
            let legacy = ["from_x", "from_y", "to_x", "to_y"]
            guard !canonical.contains(where: { arguments[$0] != nil }) || !legacy.contains(where: { arguments[$0] != nil }) else {
                throw ToolFailure(message: "Use start_x/start_y/end_x/end_y or legacy from_x/from_y/to_x/to_y, not both.")
            }
            let keys = legacy.contains(where: { arguments[$0] != nil }) ? legacy : canonical
            action = .swipe(try point(keys[0]), try point(keys[1]), try point(keys[2]), try point(keys[3]), try duration(default: 0.3)!)
        case "gesture":
            let raw = try Self.string(arguments, "preset")!
            guard let preset = MCPGesture(rawValue: raw) else {
                throw ToolFailure(message: "Unsupported gesture '\(raw)'. Use a single-finger preset from tools/list; pinch and rotation are not available.")
            }
            action = .gesture(preset, try duration(default: preset.isScroll ? 0.5 : 0.3)!)
        case "button":
            let raw = try Self.string(arguments, "button")!
            let aliases = ["recents": "app_switch", "side-button": "lock", "volume-up": "volume_up", "volume-down": "volume_down"]
            guard let button = HardwareButton(rawValue: aliases[raw] ?? raw) else {
                throw ToolFailure(message: "Unknown button '\(raw)'. See button in tools/list.")
            }
            action = .button(button, try duration())
        case "install_app":
            let path = try Self.string(arguments, "path", optional: true)
            let url = try Self.string(arguments, "url", optional: true)
            switch (path, url) {
            case (let path?, nil) where path.hasPrefix("/"):
                action = .installApp(URL(fileURLWithPath: path))
            case (nil, let url?):
                action = .installApp(try AppPackageDownload.url(url))
            default:
                throw ToolFailure(message: "Supply either an absolute local package path or an HTTP(S) download URL.")
            }
        case "launch_app": action = .launchApp(try Self.string(arguments, "bundle_id")!)
        case "type_text":
            guard let text = arguments["text"] as? String, !text.isEmpty else {
                throw ToolFailure(message: "'text' must be a non-empty string.")
            }
            guard text.count <= 10000, text.allSatisfy({ $0.asciiValue.map { (32...126).contains($0) || $0 == 10 || $0 == 9 } == true }) else {
                throw ToolFailure(message: "type_text supports at most 10000 US keyboard characters, newline and tab. No text was sent. Use the on-screen input method for Unicode.")
            }
            action = .typeText(text, try target())
        default: throw ToolFailure(message: "Unknown tool '\(name)'")
        }
    }

    static func number(_ arguments: [String: Any], _ key: String) throws -> Double {
        guard let value = arguments[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else {
            throw ToolFailure(message: "'\(key)' must be a finite number.")
        }
        return value.doubleValue
    }

    private static func optionalNumber(_ arguments: [String: Any], _ key: String, range: ClosedRange<Double>) throws -> Double? {
        guard arguments[key] != nil else { return nil }
        let value = try number(arguments, key)
        guard range.contains(value) else { throw ToolFailure(message: "'\(key)' must be between \(range.lowerBound) and \(range.upperBound) seconds.") }
        return value
    }

    static func string(_ arguments: [String: Any], _ key: String, optional: Bool = false) throws -> String? {
        if optional, arguments[key] == nil { return nil }
        guard let value = arguments[key] as? String, !value.contains("\0"), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolFailure(message: "'\(key)' must be a non-empty string.")
        }
        return value
    }
}
