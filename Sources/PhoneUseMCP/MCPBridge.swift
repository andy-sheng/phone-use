import Foundation
import PhoneUseKit

/// How `phone-use-mcp` asks the app to start without a window.
public enum PhoneUseAppBundle {
    public static let bundleIdentifier = "cn.andysheng.phoneuse"
    /// Launch argument: start without showing or activating a window, to serve MCP clients.
    public static let backgroundArgument = "--background"
}

/// The stdio side of the MCP server, run by `phone-use-mcp`.
///
/// Lifecycle and discovery requests are answered here, so an MCP client starting up does not
/// launch the app. Each `tools/call` is forwarded to the app over `socketPath`; when nothing
/// listens there, `launchApp` starts the app and the bridge waits for it to serve. Calls still
/// in flight when the app goes away fail with a tool error, and the next call reconnects.
public actor MCPBridge {
    private final class Link {
        let stream: ByteStream
        /// Request ids awaiting a reply, oldest first. The app replies to each line in order.
        var pending: [Any] = []

        init(stream: ByteStream) {
            self.stream = stream
        }
    }

    private let socketPath: String
    private let launchApp: @Sendable () async throws -> Void
    private let launchTimeout: Duration
    private let output: @Sendable (Data) -> Void
    private var link: Link?

    /// - Parameter output: writes one message; the bridge appends no newline.
    public init(socketPath: String = MCPPaths.socket,
                launchTimeout: Duration = .seconds(30),
                launchApp: @escaping @Sendable () async throws -> Void,
                output: @escaping @Sendable (Data) -> Void) {
        self.socketPath = socketPath
        self.launchTimeout = launchTimeout
        self.launchApp = launchApp
        self.output = output
    }

    /// Handles one line read from the client. Returns once the line is answered or forwarded.
    public func receive(_ line: Data) async {
        guard let message = MCPServer.decode(line) else { return }
        guard let id = message["id"] else { return } // Notifications need no reply.
        guard message["method"] as? String == "tools/call" else {
            if let reply = MCPServer.localReply(to: message) { send(reply) }
            return
        }
        let link: Link
        do {
            link = try await connect()
        } catch {
            send(MCPServer.toolError(id: id, "The PhoneUse app is not available: \(error). Ask the user to install PhoneUse, or open it once, then retry."))
            return
        }
        link.pending.append(id)
        do {
            try await link.stream.write(line + Data([0x0A]))
        } catch {
            // Closing ends the reader, which fails every pending call, this one included.
            link.stream.close()
        }
    }

    /// Waits for the calls already forwarded to be answered, then closes the connection.
    public func finish() async {
        while let link, !link.pending.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        link?.stream.close()
    }

    private func connect() async throws -> Link {
        if let link { return link }
        let stream: ByteStream
        if let open = await open() {
            stream = open
        } else {
            try await launchApp()
            stream = try await waitForApp()
        }
        // Another call may have connected while this one waited.
        if let link {
            stream.close()
            return link
        }
        let link = Link(stream: stream)
        self.link = link
        Task { await self.read(link) }
        return link
    }

    private func open() async -> ByteStream? {
        let stream = ByteStream(unixSocket: socketPath)
        do {
            try await stream.open(timeout: .seconds(1))
            return stream
        } catch {
            stream.close()
            return nil
        }
    }

    private func waitForApp() async throws -> ByteStream {
        let deadline = ContinuousClock.now + launchTimeout
        while ContinuousClock.now < deadline {
            if let stream = await open() { return stream }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw DeviceHubError.timeout("waiting for the PhoneUse app to serve MCP on \(socketPath)")
    }

    private func read(_ link: Link) async {
        var failure: Error = DeviceHubError.connectionClosed
        do {
            while true {
                let reply = try await link.stream.readLine()
                guard !reply.isEmpty else { continue }
                if !link.pending.isEmpty { link.pending.removeFirst() }
                output(reply)
            }
        } catch {
            failure = error
        }
        link.stream.close()
        if self.link === link { self.link = nil }
        let abandoned = link.pending
        link.pending.removeAll()
        for id in abandoned {
            send(MCPServer.toolError(id: id, "The PhoneUse app closed the connection (\(failure)). Retry the call to reconnect."))
        }
    }

    private func send(_ message: [String: Any]) {
        if let data = MCPServer.encode(message) { output(data) }
    }
}
