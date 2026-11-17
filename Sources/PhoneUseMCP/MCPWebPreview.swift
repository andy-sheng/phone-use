import Foundation

/// Discovers an existing CLI web service without opening a second device session or browser.
enum MCPWebPreview {
    static let workflowInstructions = "WEB PREVIEW IS A STANDARD CONNECTION STEP, including build/run/test tasks. Call connect_device separately and inspect its result before batching launch_app, screenshot or input calls. connect_device checks the web preview itself. Follow next_required_action: open_url means use your client browser tool on web_preview.url; get_web_preview means resolve the reported preview problem and call that MCP tool. If you already batched later calls, handle the repeated next_required_action now; never replay completed device actions. Do not treat preview as optional just because the user did not explicitly ask to see it."
    static let guidance = "Open the verified URL with your browser tool on the same Mac as PhoneUse before further device work, unless you already opened or presented this URL in the current client conversation. If higher-priority host rules prohibit opening a browser, the user declines, or no permitted same-Mac browser tool exists, respect that restriction: present a clickable link and explicitly explain why you could not open it. A remote/cloud browser cannot reach this Mac through its own 127.0.0.1. Do not claim a browser was opened merely because a URL was returned. PhoneUse cannot observe your browser state; this reminder is not evidence that an already opened page is closed. Continue using MCP tools to operate and verify the device, and coordinate with the user before simultaneous manual control."

    static func url(deviceID: String, port: UInt16) async throws -> URL {
        let page = URL(string: "http://127.0.0.1:\(port)/")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: page.appendingPathComponent("health"))
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.mimeType == "application/json" else { throw ProbeFailure.invalidService }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 8192 else { throw ProbeFailure.invalidService }
                data.append(byte)
            }
            try validate(data, deviceID: deviceID)
            return page
        } catch {
            let quotedDevice = "'" + deviceID.replacingOccurrences(of: "'", with: "'\\''") + "'"
            throw ToolFailure(message: "No verified PhoneUse web preview for this device at port \(port). It may be stopped, serving another device, or running an older version. On the Mac running PhoneUse, start the current CLI with: phone-use --device \(quotedDevice) serve \(port). If the port is already serving another device, choose a free port and pass it to get_web_preview. Then retry get_web_preview; do not present an unverified link as ready.")
        }
    }

    static func validate(_ data: Data, deviceID: String) throws {
        struct Health: Decodable {
            let service: String
            let device_id: String
            let frames: Int
        }
        let health = try JSONDecoder().decode(Health.self, from: data)
        guard health.service == "phone-use-web", health.device_id == deviceID, health.frames > 0 else {
            throw ProbeFailure.invalidService
        }
    }

    private enum ProbeFailure: Error { case invalidService }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// Availability belongs to a device, not a client's browser. Never store a global "opened"
/// bit: one client's lookup/open must not suppress another client's handoff instructions.
actor MCPWebPreviewWorkflow {
    struct Preview: Sendable {
        let deviceID: String
        let port: UInt16
        let url: URL?
        let error: String?

        func appending(to result: [String: Any]) -> [String: Any] {
            var result = result
            var output = result["structuredContent"] as? [String: Any] ?? [:]
            var preview: [String: Any] = ["available": url != nil, "port": Int(port),
                "same_host_required": true, "browser_opened_by_tool": false]
            let next: String
            let note: String
            if let url {
                preview["url"] = url.absoluteString
                next = "open_url"
                output["next_action_target"] = "client_browser"
                output["next_action_arguments"] = ["url": url.absoluteString]
                note = "NEXT REQUIRED ACTION: open_url \(url.absoluteString). This is a client-browser step, not a PhoneUse MCP tool. " + MCPWebPreview.guidance
            } else {
                preview["error"] = error ?? "Web preview unavailable"
                next = "get_web_preview"
                output["next_action_target"] = "phoneuse_mcp"
                output["next_action_arguments"] = ["device": deviceID, "port": Int(port)]
                note = "NEXT REQUIRED ACTION: get_web_preview for device \(deviceID), port \(port). Resolve this preview issue first: \(error ?? "Web preview unavailable"). The preceding device result still stands; do not repeat completed actions. If host restrictions prevent resolution, explain the blocker to the user."
            }
            output["web_preview"] = preview
            // Pending means URL verification is outstanding, not that we know browser state.
            output["web_preview_pending"] = url == nil
            output["next_required_action"] = next
            result["structuredContent"] = output
            var content = result["content"] as? [[String: Any]] ?? []
            content.append(mcpText(note))
            result["content"] = content
            return result
        }
    }

    private struct Entry {
        let checkedAt: Date
        let preview: Preview
    }
    private var entries: [String: Entry] = [:]
    private let maxAge: TimeInterval

    init(maxAge: TimeInterval = 5) { self.maxAge = maxAge }

    func lookup(deviceID: String, port explicitPort: UInt16? = nil, force: Bool = false,
                probe: @Sendable (String, UInt16) async throws -> URL) async -> Preview {
        let previous = entries[deviceID]
        let port = explicitPort ?? previous?.preview.port ?? 8765
        if !force, let previous, previous.preview.port == port,
           Date().timeIntervalSince(previous.checkedAt) < maxAge { return previous.preview }
        let preview: Preview
        do {
            preview = Preview(deviceID: deviceID, port: port, url: try await probe(deviceID, port), error: nil)
        } catch {
            preview = Preview(deviceID: deviceID, port: port, url: nil,
                              error: (error as? ToolFailure)?.message ?? String(describing: error))
        }
        if entries.count >= 64, entries[deviceID] == nil { entries.removeAll() }
        entries[deviceID] = Entry(checkedAt: Date(), preview: preview)
        return preview
    }
}
