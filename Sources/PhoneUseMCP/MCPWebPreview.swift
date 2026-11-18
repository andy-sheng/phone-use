import Foundation

/// Discovers an existing CLI web service without opening a second device session or browser.
enum MCPWebPreview {
    static let workflowInstructions = "Read the connect_device result before continuing. It provides the web preview handoff once at connection. Use only your agent's built-in web preview for the returned URL, subject to the user and host's rules."

    static func openInstruction(for url: URL) -> String {
        """
        Open \(url.absoluteString) in your agent's built-in web preview if permitted and the URL is not already open. \
        In T3 Code, check preview_status first. For a new tab, call preview_open with {"url":"\(url.absoluteString)","open":true,"reuseExistingTab":false}. \
        If your agent has no permitted preview that can reach the PhoneUse Mac, share the verified URL and continue with device tools.
        """
    }

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
        let port: UInt16
        let url: URL?
        let error: String?

        var status: [String: Any] {
            var status: [String: Any] = ["available": url != nil, "port": Int(port),
                "same_host_required": true, "browser_opened_by_tool": false]
            status["url"] = url?.absoluteString
            status["error"] = error
            return status
        }
    }

    private var ports: [String: UInt16] = [:]

    func lookup(deviceID: String, port explicitPort: UInt16? = nil,
                probe: @Sendable (String, UInt16) async throws -> URL) async -> Preview {
        if let explicitPort {
            if ports.count >= 64, ports[deviceID] == nil { ports.removeAll() }
            ports[deviceID] = explicitPort
        }
        let port = ports[deviceID] ?? 8765
        do {
            return Preview(port: port, url: try await probe(deviceID, port), error: nil)
        } catch {
            return Preview(port: port, url: nil, error: (error as? ToolFailure)?.message ?? String(describing: error))
        }
    }
}
