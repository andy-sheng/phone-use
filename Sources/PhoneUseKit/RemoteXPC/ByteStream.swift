import Foundation
import Network

/// An async byte stream over a Network.framework connection.
public final class ByteStream: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "devicehub.bytestream")
    private var buffer = Data()

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
    }

    /// Wraps a connection a listener accepted; `open()` starts it.
    public init(accepted connection: NWConnection) {
        self.connection = connection
    }

    convenience init(host: String = "127.0.0.1", port: UInt16) {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!))
    }

    public convenience init(unixSocket path: String) {
        self.init(endpoint: .unix(path: path))
    }

    public func open(timeout: Duration = .seconds(5)) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = Resumed()
            connection.stateUpdateHandler = { [connection] state in
                switch state {
                case .ready:
                    if resumed.claim() { continuation.resume() }
                case .failed(let error):
                    if resumed.claim() { continuation.resume(throwing: error) }
                case .waiting(let error):
                    // Loopback endpoints that refuse connections never recover by waiting.
                    connection.cancel()
                    if resumed.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if resumed.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) { [connection] in
                if resumed.claim() {
                    connection.cancel()
                    continuation.resume(throwing: DeviceHubError.timeout("connecting to \(connection.endpoint)"))
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// Reads exactly `count` bytes; throws `DeviceHubError.connectionClosed` at end of stream.
    public func read(exactly count: Int) async throws -> Data {
        while buffer.count < count {
            let chunk = try await receive()
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }

    /// Reads up to and excluding the next newline.
    public func readLine() async throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex ..< newline]
                buffer.removeSubrange(buffer.startIndex ... newline)
                return Data(line)
            }
            buffer.append(try await receive())
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(throwing: DeviceHubError.connectionClosed)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func close() {
        connection.cancel()
    }
}

/// Ensures a continuation is resumed exactly once across competing callbacks.
public final class Resumed: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    public init() {}

    public func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
