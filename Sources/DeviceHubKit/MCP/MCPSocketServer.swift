import Foundation
import Network

public extension DeviceHubPaths {
    /// Where the app serves MCP tool calls to `phone-use-mcp`. `DEVICEHUB_MCP_SOCKET` overrides it.
    static var mcpSocket: String {
        if let override = ProcessInfo.processInfo.environment["DEVICEHUB_MCP_SOCKET"], !override.isEmpty {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeviceHub/mcp.sock").path
    }
}

/// Serves newline-delimited messages on a Unix socket, one handler call per line.
///
/// Each connection is handled in order: a line's reply is written before the next line is read,
/// which lets the bridge match replies to requests. The socket is only accessible to this user.
public final class MCPSocketServer: @unchecked Sendable {
    public enum StartError: Error, CustomStringConvertible {
        case alreadyServing(String)
        case failed(String)

        public var description: String {
            switch self {
            case .alreadyServing(let path): "Another phone-use instance already serves MCP on \(path)"
            case .failed(let reason): "Could not serve MCP: \(reason)"
            }
        }
    }

    public typealias Handler = @Sendable (Data) async -> Data?

    private let path: String
    private let handler: Handler
    private let onConnectionCountChange: @Sendable (Int) -> Void
    private let queue = DispatchQueue(label: "devicehub.mcp.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ByteStream] = [:]

    public init(path: String = DeviceHubPaths.mcpSocket, handler: @escaping Handler,
                onConnectionCountChange: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.path = path
        self.handler = handler
        self.onConnectionCountChange = onConnectionCountChange
    }

    /// Starts listening. A leftover socket file is replaced, but a live server is left alone.
    public func start() async throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            if await Self.isServing(path) { throw StartError.alreadyServing(path) }
            unlink(path)
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw StartError.failed("\(error)")
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Resumed()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error), .waiting(let error):
                    // A listener that cannot bind waits forever rather than failing.
                    listener.cancel()
                    if resumed.claim() { continuation.resume(throwing: StartError.failed("\(error)")) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: StartError.failed("listener cancelled")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        chmod(path, 0o600)
        lock.withLock { self.listener = listener }
    }

    /// Stops listening and closes every connection.
    public func stop() {
        let (listener, open) = lock.withLock {
            defer { self.listener = nil; connections.removeAll() }
            return (self.listener, Array(connections.values))
        }
        guard let listener else { return }
        listener.cancel()
        // Closing a stream ends its connection's read loop.
        for stream in open { stream.close() }
        unlink(path)
        if !open.isEmpty { onConnectionCountChange(0) }
    }

    /// Whether something accepts connections on `path` right now.
    public static func isServing(_ path: String) async -> Bool {
        let stream = ByteStream(unixSocket: path)
        defer { stream.close() }
        do {
            try await stream.open(timeout: .seconds(1))
            return true
        } catch {
            return false
        }
    }

    private func accept(_ connection: NWConnection) {
        let stream = ByteStream(accepted: connection)
        let key = ObjectIdentifier(stream)
        // Registered before the read loop starts, so `finished` always finds it.
        let count = lock.withLock {
            connections[key] = stream
            return connections.count
        }
        onConnectionCountChange(count)
        let handler = handler
        Task { [weak self] in
            do {
                try await stream.open()
                while true {
                    let line = try await stream.readLine()
                    guard !line.isEmpty, let reply = await handler(line) else { continue }
                    try await stream.write(reply + Data([0x0A]))
                }
            } catch {
                // The peer went away or the server stopped; nothing to report back to.
            }
            stream.close()
            self?.finished(key)
        }
    }

    private func finished(_ key: ObjectIdentifier) {
        let count: Int? = lock.withLock {
            guard connections.removeValue(forKey: key) != nil else { return nil }
            return connections.count
        }
        if let count { onConnectionCountChange(count) }
    }
}
