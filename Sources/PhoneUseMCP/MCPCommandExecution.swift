import CoreGraphics
import Foundation
import PhoneUseKit

/// Test seam at the existing shared-session boundary; production still uses DeviceHub.shared.
protocol MCPDeviceSession: Sendable {
    var device: DeviceSummary { get }
    var display: DisplayInfo { get }
    func screenshot() async throws -> CGImage
    func tap(x: Double, y: Double) async throws
    func longPress(x: Double, y: Double, duration: Duration) async throws
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, duration: Duration) async throws
    func press(_ button: HardwareButton, duration: Duration?) async throws
    func launchApp(bundleID: String) async throws
    func uiTree() async throws -> UITree
    func activate(_ selector: UISelector) async throws
    func typeText(_ text: String, target: UISelector?) async throws
}

extension DeviceSession: MCPDeviceSession {}

struct MCPDeviceAccess: Sendable {
    let devices: @Sendable () async throws -> [DeviceSummary]
    let session: @Sendable (String) async throws -> any MCPDeviceSession
    var files: @Sendable (DeviceSummary) throws -> any DeviceFileAccess = { try DeviceFiles(device: $0) }
    var webPreview: @Sendable (String, UInt16) async throws -> URL = { _, _ in
        throw ToolFailure(message: "Web preview discovery is not configured")
    }
    var previewWorkflow = MCPWebPreviewWorkflow()

    static let live = MCPDeviceAccess(devices: { try await DeviceHub.shared.devices() },
                                     session: { try await DeviceHub.shared.session(for: $0) },
                                     webPreview: { try await MCPWebPreview.url(deviceID: $0, port: $1) })
}

extension MCPCommand {
    static func resolve(_ query: String?, in devices: [DeviceSummary], requiresReady: Bool = true) throws -> DeviceSummary {
        let candidates: [DeviceSummary]
        if let query {
            let needle = query.lowercased()
            let exact = devices.filter { $0.udid.lowercased() == needle || $0.deviceIdentifier.lowercased() == needle || $0.name.lowercased() == needle }
            candidates = exact.isEmpty ? devices.filter { $0.name.lowercased().contains(needle) } : exact
        } else {
            candidates = devices.filter(\.isReady)
            if candidates.isEmpty, let attached = devices.first(where: \.isAttached) {
                throw DeviceHubError.deviceNotReady("\(attached.name) is not ready (\(attached.state.rawValue))")
            }
        }
        guard !candidates.isEmpty else { throw DeviceHubError.deviceNotFound(query ?? "<any ready device>") }
        guard candidates.count == 1 else {
            throw ToolFailure(message: "More than one device matches. Call list_devices and pass an explicit device identifier: \(candidates.map(\.udid).joined(separator: ", ")).")
        }
        guard !requiresReady || candidates[0].isReady else { throw DeviceHubError.deviceNotReady("\(candidates[0].name) is not ready (\(candidates[0].state.rawValue))") }
        return candidates[0]
    }

    func execute(access: MCPDeviceAccess, workspace: MCPWorkspaceAccess? = nil) async throws -> [String: Any] {
        let devices = try await access.devices()
        let selection = await workspace?.selectedDevice()
        if case .listDevices = action {
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(devices)) as? [[String: Any]] ?? []
            let rows = zip(devices, encoded).map { device, row in
                var capabilities = ["screenshot", "tap", "long_press", "swipe", "gesture", "button", "launch_app"]
                if !device.isAndroid { capabilities += ["describe_ui", "element_targeting"] }
                if device.isSimulator || !device.isAndroid && device.osMajorVersion >= 27 { capabilities.append("type_text") }
                return row.merging(["capabilities": capabilities, "selected": device.udid == selection,
                    "ui_scope": device.isAndroid ? "unavailable" : device.isSimulator ? "accessibility" : "development-signed foreground app (get-task-allow=true); no element geometry",
                    "coordinate_unit": device.isAndroid ? "pixels" : "points"]) { _, new in new }
            }
            return ["content": [mcpText(try json(rows))], "structuredContent": ["devices": rows]]
        }
        let query = device ?? selection
        if case .selectDevice = action {
            let selected = try Self.resolve(device, in: devices, requiresReady: false)
            guard let workspace else { throw ToolFailure(message: "Device selection requires the PhoneUse app host.") }
            try await workspace.select(selected)
            return ["content": [mcpText("Selected \(selected.name). Call connect_device to connect.")],
                    "structuredContent": ["device": selected.udid, "selected": true, "state": selected.state.rawValue]]
        }
        let selected = try Self.resolve(query, in: devices)
        if case .webPreview(let port) = action {
            let preview = await access.previewWorkflow.lookup(deviceID: selected.udid, port: port, probe: access.webPreview)
            guard let url = preview.url else { throw ToolFailure(message: preview.error ?? "Web preview unavailable") }
            return ["content": [mcpText("Live web preview for \(selected.name) at \(url.absoluteString)")],
                    "structuredContent": ["device": selected.udid, "url": url.absoluteString, "available": true,
                                          "browser_opened": false, "same_host_required": true,
                                          "web_preview": preview.status, "web_preview_pending": false]]
        }
        if let result = try await executeFiles(selected: selected, access: access) { return result }
        if case .connectDevice = action {
            guard let workspace else { throw ToolFailure(message: "Explicit device connection requires the PhoneUse app host.") }
            try await workspace.connect(selected)
            let preview = await access.previewWorkflow.lookup(deviceID: selected.udid, probe: access.webPreview)
            var output: [String: Any] = ["device": selected.udid, "selected": true, "session_connected": true,
                                        "preview_requested": true, "first_frame_verified": false,
                                        "web_preview": preview.status, "web_preview_pending": preview.url == nil]
            var content = [mcpText("Connected to \(selected.name). Requested the native PhoneUse preview.")]
            if let url = preview.url {
                output["next_required_action"] = "open_url"
                output["next_action_target"] = "client_browser"
                output["next_action_arguments"] = ["url": url.absoluteString]
                content.append(mcpText(MCPWebPreview.openInstruction(for: url)))
            } else if let error = preview.error {
                content.append(mcpText("Web preview unavailable. \(error) You can continue with device tools."))
            }
            return ["content": content, "structuredContent": output]
        }
        let session = try await access.session(selected.udid)
        let width = selected.isAndroid ? session.display.pixelWidth : session.display.pointWidth.rounded()
        let height = selected.isAndroid ? session.display.pixelHeight : session.display.pointHeight.rounded()
        guard width.isFinite, height.isFinite, width > 0, height > 0, width <= 32768, height <= 32768 else {
            throw ToolFailure(message: "Invalid display geometry. Reconnect the device before sending input.")
        }
        let unit = selected.isAndroid ? "pixels" : "points"
        let metadata: [String: Any] = ["device": selected.udid, "platform": selected.platform.rawValue,
            "connection": selected.connection, "width": width, "height": height, "unit": unit,
            "origin": "top-left", "coordinate_space": selected.isAndroid ? "display" : "native-portrait"]

        func point(_ x: Double, _ y: Double) throws -> (Double, Double) {
            guard (0...width).contains(x), (0...height).contains(y) else {
                throw ToolFailure(message: "Point (\(x), \(y)) is outside \(width)x\(height) \(unit). Capture screenshot again before retrying.")
            }
            return (x / width, y / height)
        }
        func screen() async throws -> [[String: Any]] {
            let image = try await session.screenshot()
            guard let scaled = ImageEncoding.resized(image, width: Int(width), height: Int(height)),
                  let jpeg = ImageEncoding.jpeg(scaled) else { throw ToolFailure(message: "Failed to encode screenshot") }
            return [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"],
                    mcpText("Screen of \(selected.name): \(Int(width))x\(Int(height)) \(unit), origin top-left, \(metadata["coordinate_space"]!).")]
        }

        // Validate both endpoints and platform limits before delays or the first input event.
        switch action {
        case .tap(let x, let y, _), .longPress(let x, let y, _): _ = try point(x, y)
        case .swipe(let x1, let y1, let x2, let y2, _): _ = try point(x1, y1); _ = try point(x2, y2)
        case .button(let button, _):
            if selected.isAndroid && button == .siri || !selected.isAndroid && (button == .back || button == .appSwitch) {
                throw ToolFailure(message: "Button \(button.rawValue) is unavailable on \(selected.platform.rawValue). back/recents are Android-only; siri is iOS-only.")
            }
        case .describeUI, .activate, .typeText:
            guard !selected.isAndroid else {
                throw ToolFailure(message: "UI trees, element targeting and direct text input are currently unavailable on Android. Use screenshot, coordinate tap and the on-screen keyboard for this device.")
            }
        default: break
        }
        if case .typeText(let text, _) = action, !selected.isSimulator {
            guard session.device.osMajorVersion >= 27, text.count <= 500 else {
                throw ToolFailure(message: "Physical iOS type_text requires iOS 27+ and accepts up to 500 US keyboard characters per call. Use the on-screen keyboard on older devices.")
            }
        }
        if case .screenshot = action { return ["content": try await screen(), "structuredContent": metadata] }
        if case .describeUI(let useJSON) = action {
            let tree = try await session.uiTree()
            let treeData = try JSONEncoder().encode(tree)
            let value = try JSONSerialization.jsonObject(with: treeData)
            return ["content": [mcpText(useJSON ? String(decoding: treeData, as: UTF8.self) : tree.outline)],
                    "structuredContent": ["device": selected.udid, "tree": value]]
        }

        if preDelay > .zero { try await Task.sleep(for: preDelay) }
        let summary: String
        switch action {
        case .tap(let x, let y, let duration):
            let (nx, ny) = try point(x, y)
            if let duration { try await session.longPress(x: nx, y: ny, duration: duration) }
            else { try await session.tap(x: nx, y: ny) }
            summary = "Tap input sent at (\(x), \(y))."
        case .longPress(let x, let y, let duration):
            let (nx, ny) = try point(x, y)
            try await session.longPress(x: nx, y: ny, duration: duration)
            summary = "Long-press input sent at (\(x), \(y))."
        case .swipe(let x1, let y1, let x2, let y2, let duration):
            let from = try point(x1, y1), to = try point(x2, y2)
            try await session.swipe(fromX: from.0, fromY: from.1, toX: to.0, toY: to.1, duration: duration)
            summary = "Swipe input sent from (\(x1), \(y1)) to (\(x2), \(y2))."
        case .gesture(let preset, let duration):
            let s = preset.stroke
            try await session.swipe(fromX: s.fromX, fromY: s.fromY, toX: s.toX, toY: s.toY, duration: duration)
            summary = "Gesture input sent: \(preset.rawValue)."
        case .button(let button, let duration):
            try await session.press(button, duration: duration)
            summary = "Button input sent: \(button.rawValue)."
        case .launchApp(let bundleID):
            try await session.launchApp(bundleID: bundleID)
            summary = "Launch request sent for \(bundleID)."
        case .activate(let selector):
            try await session.activate(selector)
            summary = "Element activation sent."
        case .typeText(let text, let target):
            try await session.typeText(text, target: target)
            summary = "Text input sent (\(text.count) characters)."
        default: throw ToolFailure(message: "Unsupported action")
        }
        if postDelay > .zero { try await Task.sleep(for: postDelay) }
        var content = [mcpText(summary + " Verify the resulting UI with describe_ui (supported iOS apps) or screenshot before the next action.")]
        var output: [String: Any] = ["device": selected.udid, "input_sent": true, "ui_change_verified": false]
        if returnScreen {
            do {
                try await Task.sleep(for: .milliseconds(600))
                content += try await screen()
                output["screen"] = metadata
            } catch {
                // A tool-level failure here would invite duplicate taps or partially typed text.
                content.append(mcpText("The action was sent, but the follow-up screenshot failed: \(error). Inspect the screen before retrying; do not repeat the action automatically."))
                output["screenshot_error"] = String(describing: error)
            }
        }
        return ["content": content, "structuredContent": output]
    }
}

extension MCPCommand {
    /// File operations resolve the shared device selection, but never start video or input.
    private func executeFiles(selected: DeviceSummary, access: MCPDeviceAccess) async throws -> [String: Any]? {
        switch action {
        case .listApps, .listSandboxFiles, .readSandboxFile, .downloadSandboxFile: break
        default: return nil
        }
        guard !selected.isAndroid else { throw ToolFailure(message: "App sandbox tools currently support iOS only.") }
        let files = try access.files(selected)
        func encoded<T: Encodable>(_ value: T) throws -> Any {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        }
        var output: [String: Any] = ["device": selected.udid]
        var content: String
        switch action {
        case .listApps(let search):
            let apps = try await files.apps().filter {
                guard let search else { return true }
                return $0.name.localizedCaseInsensitiveContains(search) || $0.bundleIdentifier.localizedCaseInsensitiveContains(search)
            }
            output["apps"] = try encoded(apps)
            content = try json(output)
        case .listSandboxFiles(let bundle, let path, let offset, let limit):
            let entries = try await files.list(bundleID: bundle, path: path)
            let page = Array(entries.dropFirst(offset).prefix(limit))
            output.merge(["bundle_id": bundle, "path": path, "files": try encoded(page), "total": entries.count,
                          "offset": offset]) { _, new in new }
            if offset + page.count < entries.count { output["next_offset"] = offset + page.count }
            content = try json(output)
        case .readSandboxFile(let bundle, let path):
            let text = try await files.readText(bundleID: bundle, path: path)
            output.merge(["bundle_id": bundle, "path": path, "encoding": "utf-8", "text": text]) { _, new in new }
            content = try json(output)
        case .downloadSandboxFile(let bundle, let path, let destination):
            try await files.download(bundleID: bundle, path: path, to: destination)
            output.merge(["bundle_id": bundle, "path": path, "local_path": destination.path]) { _, new in new }
            content = try json(output)
        default: return nil
        }
        return ["content": [mcpText(content)], "structuredContent": output]
    }
}

private func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
}
