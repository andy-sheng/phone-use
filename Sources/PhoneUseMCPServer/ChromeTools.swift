import Darwin
import Foundation
import PhoneUseMCP

/// Merge the packaged upstream catalog into the existing server. Only a web tool call
/// starts its private MCP process. Each stdio client gets its own upstream session.
actor ChromeTools {
    private let names: Set<String>
    private let arguments: [String]
    private let output: StandardOutput
    private var initialization: [String: Any] = [
        "protocolVersion": "2025-06-18", "clientInfo": ["name": "phone-use", "version": MCPServer.version],
        "capabilities": [String: Any]()
    ]

    private final class Session {
        let process = Process()
        let input = Pipe()
        let initID = UUID().uuidString
        var ready = false
        var queued: [[String: Any]] = []
        var pending: Set<AnyHashable> = []
        var serverRequests: [String: Any] = [:]
    }
    private var session: Session?

    static func loadCatalog() -> [[String: Any]] {
        do {
            let data = try Data(contentsOf: ChromeRuntime.directory.appendingPathComponent("tools.json"))
            let tools = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            guard let tools, !tools.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            return try tools.map { definition in
                guard let name = definition["name"] as? String else { throw CocoaError(.fileReadCorruptFile) }
                var renamed = definition
                renamed["name"] = "chrome_" + name
                return renamed
            }
        } catch {
            FileHandle.standardError.write(Data("phone-use-mcp: Chrome tool catalog unavailable: \(error.localizedDescription)\n".utf8))
            return []
        }
    }

    init(catalog: [[String: Any]], arguments: [String], output: StandardOutput) {
        self.arguments = arguments
        self.output = output
        names = Set(catalog.compactMap { $0["name"] as? String })
    }

    /// Return false for messages belonging to the native PhoneUse bridge.
    func receive(_ line: Data) -> Bool {
        guard var message = MCPServer.decode(line) else { return false }
        let method = message["method"] as? String
        var params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            initialization = params
            return false
        case "tools/call":
            guard let name = params["name"] as? String, names.contains(name),
                  let id = message["id"] as? AnyHashable else { return false }
            params["name"] = String(name.dropFirst("chrome_".count))
            message["params"] = params
            do {
                let current = try session ?? start()
                current.pending.insert(id)
                forward(message, to: current)
            } catch {
                send(MCPServer.toolError(id: id, "Starting Chrome DevTools MCP failed: \(error.localizedDescription)"))
            }
        case "notifications/cancelled":
            guard let current = session, let id = params["requestId"] as? AnyHashable,
                  current.pending.contains(id) else { return false }
            forward(message, to: current)
        case "notifications/roots/list_changed":
            if let current = session { forward(message, to: current) }
        case nil:
            guard let current = session, let id = message["id"] as? String,
                  let upstream = current.serverRequests.removeValue(forKey: id) else { return false }
            message["id"] = upstream
            forward(message, to: current)
        default:
            return false
        }
        return true
    }

    private func start() throws -> Session {
        let current = Session()
        let stdout = Pipe()
        current.process.executableURL = ChromeRuntime.executable
        current.process.arguments = ["chrome-devtools"] + arguments
        current.process.standardInput = current.input
        current.process.standardOutput = stdout
        current.process.standardError = FileHandle.standardError
        try current.process.run()
        session = current
        Task.detached { [self] in
            let handle = stdout.fileHandleForReading
            var line = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                // A pipe can stay open for hours. Read available bytes without waiting
                // for a full buffer before delivering a short JSON-RPC response.
                let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }
                let chunk = buffer.prefix(count)
                var start = chunk.startIndex
                while let lf = chunk[start...].firstIndex(of: 0x0a) {
                    line.append(contentsOf: chunk[start..<lf])
                    await received(line, from: current)
                    line.removeAll(keepingCapacity: true)
                    start = chunk.index(after: lf)
                }
                line.append(contentsOf: chunk[start...])
            }
            try? handle.close()
            await stopped(current, reason: "Chrome DevTools MCP disconnected. Retry to reconnect.")
        }
        write(["jsonrpc": "2.0", "id": current.initID, "method": "initialize", "params": initialization], to: current)
        guard session === current else { throw CocoaError(.fileWriteUnknown) }
        return current
    }

    private func received(_ line: Data, from current: Session) {
        guard session === current, var message = MCPServer.decode(line) else { return }
        if message["id"] as? String == current.initID && !current.ready {
            guard message["result"] != nil else {
                stopped(current, reason: "Chrome DevTools MCP initialization failed.")
                return
            }
            write(["jsonrpc": "2.0", "method": "notifications/initialized"], to: current)
            current.ready = true
            for request in current.queued { write(request, to: current) }
            current.queued.removeAll()
        } else if message["method"] != nil, let id = message["id"] {
            // Server-initiated requests (e.g. roots/list) have their own ID space.
            let external = UUID().uuidString
            current.serverRequests[external] = id
            message["id"] = external
            send(message)
        } else {
            if let id = message["id"] as? AnyHashable { current.pending.remove(id) }
            output.write(line)
        }
    }

    private func forward(_ message: [String: Any], to current: Session) {
        if current.ready { write(message, to: current) } else { current.queued.append(message) }
    }

    private func write(_ message: [String: Any], to current: Session) {
        guard session === current, var data = MCPServer.encode(message) else { return }
        data.append(0x0a)
        do { try current.input.fileHandleForWriting.write(contentsOf: data) }
        catch { stopped(current, reason: "Chrome DevTools MCP input closed. Retry to reconnect.") }
    }

    private func send(_ message: [String: Any]) {
        if let data = MCPServer.encode(message) { output.write(data) }
    }

    private func stopped(_ current: Session, reason: String) {
        guard session === current else { return }
        session = nil
        try? current.input.fileHandleForWriting.close()
        for id in current.pending { send(MCPServer.toolError(id: id, reason)) }
    }

    func finish() async {
        guard let current = session else { return }
        // Give already submitted requests a chance to finish when clients pipe input and close.
        let deadline = ContinuousClock.now + .seconds(5)
        while !current.pending.isEmpty && session === current && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        stopped(current, reason: "MCP client closed its input.")
    }
}
