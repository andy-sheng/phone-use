import Foundation
import PhoneUseKit

// MCP tool definitions and dispatch, shared by the stdio bridge (`phone-use-mcp`), which answers
// lifecycle and discovery requests itself, and the app, which runs every `tools/call`.
// Messages are newline-delimited JSON-RPC 2.0. Coordinates are iOS points or Android pixels with
// the origin at the top-left, matching the image returned by `screenshot`.

/// The phone-use MCP server, independent of transport.
public enum MCPServer {
    public static let name = "phone-use"
    public static let version = "0.3.0"

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
                "instructions": "Call list_devices. For a shut down simulator, call start_simulator by identifier and wait for ready. Select the device with select_device, then call connect_device. " + MCPWebPreview.workflowInstructions + " Check lock_state in list_devices and again in connect_device. When locked, follow unlock_hint before launching apps or sending input. When lock_state is unknown, inspect the current UI first. A black screenshot alone cannot establish the lock state. Selection is shared with the UI and all clients; pass device explicitly when agents run concurrently. Observe with describe_ui (Android or iOS; physical iOS requires a development-signed foreground app) or screenshot. Prefer fresh id/label selectors for iOS element taps. Verify the resulting UI after every action; input delivery is not proof of a UI change. Coordinates are iOS native portrait points or Android display pixels; durations and delays are seconds. Physical iOS UI trees and selectors require get-task-allow=true and omit geometry. Physical US-keyboard type_text requires iOS 27+ (500 characters per call); simulator typing accepts 10000 characters.",
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": MCPToolCatalog.definitions])
        case "tools/call":
            return nil
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
    }

    /// Handles one request, running tools against `DeviceHub.shared` after `prepare` (which the
    /// app uses to make sure its daemon is up). Returns nil for notifications.
    public static func handle(_ message: [String: Any],
                              prepare: @Sendable () async throws -> Void = {},
                              workspace: MCPWorkspaceAccess? = nil) async -> [String: Any]? {
        await handle(message, prepare: prepare, access: .live, workspace: workspace)
    }

    static func handle(_ message: [String: Any], prepare: @Sendable () async throws -> Void = {},
                       access: MCPDeviceAccess, workspace: MCPWorkspaceAccess? = nil) async -> [String: Any]? {
        guard let id = message["id"] else { return nil }
        guard message["method"] as? String == "tools/call" else { return localReply(to: message) }
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        do {
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                throw ToolFailure(message: "Tool arguments must be an object.")
            }
            let command = try MCPCommand(name: name, arguments: params["arguments"] as? [String: Any] ?? [:])
            // The capture belongs to the host and can be finalized after a device disconnects.
            if case .stopRecording(let recordingID) = command.action {
                let movie = try await access.recordings.stop(recordingID)
                return result(id, ["content": [mcpText("Saved recording to \(movie.url.path)")],
                                   "structuredContent": movie.metadata])
            }
            try await prepare()
            return result(id, try await command.execute(access: access, workspace: workspace))
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
            return "\(error). Call list_devices to see what is connected. If the device is missing, ask the user to connect it by USB, put it on the same Wi-Fi as this Mac, or boot the intended iOS simulator in Xcode/Simulator, then retry."
        case .deviceNotReady:
            return "\(error). Ask the user to open PhoneUse and finish setting up this device there (trust this Mac, pairing, Developer Mode), then retry."
        case .daemonUnavailable(let detail):
            return "PhoneUse could not reach its device service (\(detail)). Ask the user to open PhoneUse and check the message it shows, then retry."
        default:
            return "\(error)"
        }
    }

    /// Gives active recording backends time to finalize their files before the app exits.
    @MainActor public static func finishRecordingsBeforeTermination() -> Task<Void, Never>? {
        MCPDeviceAccess.live.recordings.finishBeforeTermination()
    }

    /// Handles one encoded line; nil when there is nothing to send back.
    public static func handle(line: Data, prepare: @Sendable () async throws -> Void = {},
                              workspace: MCPWorkspaceAccess? = nil) async -> Data? {
        guard let message = decode(line), let reply = await handle(message, prepare: prepare, workspace: workspace) else { return nil }
        return encode(reply)
    }

    /// A `tools/call` result reporting `message` as a tool error, which the agent gets to read.
    public static func toolError(id: Any, _ message: String) -> [String: Any] {
        result(id, ["content": [mcpText(message)], "isError": true])
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

func mcpText(_ value: String) -> [String: Any] {
    ["type": "text", "text": value]
}
