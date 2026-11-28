import AppKit

/// How MCP clients are told about `phone-use-mcp`: the commands and configuration the MCP
/// settings page shows, and the one-click setup that runs a client's own `mcp add`.
struct MCPClientSetup {
    static let serverName = "phone-use"

    enum Client: String, CaseIterable, Identifiable {
        case claudeCode
        case codex
        case codeBuddyCode

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .codeBuddyCode: "CodeBuddy Code（CLI）"
            }
        }

        /// The command-line tool that manages this client's MCP servers.
        var executableName: String {
            switch self {
            case .claudeCode: "claude"
            case .codex: "codex"
            case .codeBuddyCode: "codebuddy"
            }
        }
    }

    enum DesktopClient: String, CaseIterable, Identifiable {
        case cursor = "Cursor"
        case workBuddy = "WorkBuddy"
        case codeBuddy = "CodeBuddy IDE"

        var id: Self { self }

        var isInstalled: Bool {
            let identifiers: [String]
            switch self {
            case .cursor: identifiers = ["com.todesktop.230313mzl4w4u92"]
            case .workBuddy: identifiers = ["com.tencent.workbuddy.mac"]
            case .codeBuddy: identifiers = ["com.tencent.codebuddycn", "com.tencent.codebuddy"]
            }
            return identifiers.contains { id in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
                return FileManager.default.fileExists(atPath: url.path)
            }
        }

        var configPath: String? {
            switch self {
            case .cursor: nil // Cursor imports via its install link.
            case .workBuddy: ".workbuddy/mcp.json"
            case .codeBuddy: ".codebuddy/mcp.json"
            }
        }
    }

    /// Absolute path of `phone-use-mcp`.
    let serverPath: String

    /// User scope for Claude Code, so the server is available in every project.
    func addArguments(_ client: Client) -> [String] {
        switch client {
        case .claudeCode: ["mcp", "add", "-s", "user", Self.serverName, "--", serverPath]
        case .codex: ["mcp", "add", Self.serverName, "--", serverPath]
        case .codeBuddyCode: ["mcp", "add", "--scope", "user", Self.serverName, "--", serverPath]
        }
    }

    func removeArguments(_ client: Client) -> [String] {
        switch client {
        case .claudeCode: ["mcp", "remove", "-s", "user", Self.serverName]
        case .codex: ["mcp", "remove", Self.serverName]
        case .codeBuddyCode: ["mcp", "remove", Self.serverName, "--scope", "user"]
        }
    }

    func getArguments(_ client: Client) -> [String] {
        ["mcp", "get", Self.serverName]
    }

    /// The add command as typed in a terminal.
    func shellCommand(_ client: Client) -> String {
        ([client.executableName] + addArguments(client)).map(Self.shellQuoted).joined(separator: " ")
    }

    private var serverConfiguration: [String: String] { ["command": serverPath] }

    func install(in configurationURL: URL) throws {
        let url = configurationURL.resolvingSymlinksInPath()
        var config: [String: Any] = [:]
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            config = object
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var servers: [String: Any] = [:]
        if let existing = config["mcpServers"] {
            guard let entries = existing as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
            servers = entries
        }
        let existing = servers[Self.serverName] as? [String: Any]
        var entry = existing?["url"] == nil ? existing ?? [:] : [:]
        entry["type"] = "stdio"
        entry["command"] = serverPath
        entry["args"] = [String]()
        if let existing, NSDictionary(dictionary: existing).isEqual(to: entry) { return }
        servers[Self.serverName] = entry
        config["mcpServers"] = servers
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    var cursorInstallURL: URL? {
        guard let data = try? JSONEncoder().encode(serverConfiguration),
              let config = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .alphanumerics)
        else { return nil }
        var link = URLComponents()
        link.scheme = "cursor"
        link.host = "anysphere.cursor-deeplink"
        link.path = "/mcp/install"
        link.percentEncodedQueryItems = [URLQueryItem(name: "name", value: Self.serverName),
                                         URLQueryItem(name: "config", value: config)]
        return link.url
    }

    /// The `mcpServers` entry JSON-configured clients (Claude Desktop, Cursor, …) take.
    var jsonConfiguration: String {
        let configuration = ["mcpServers": [Self.serverName: serverConfiguration]]
        let data = try? JSONSerialization.data(withJSONObject: configuration,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// Whether `mcp get` output describes a server started from this `serverPath`.
    func describesThisServer(_ output: String) -> Bool {
        output.contains(serverPath)
    }

    static func shellQuoted(_ argument: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy(safe.contains) { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// `Contents/Helpers/phone-use-mcp` in the app bundle, or the `phone-use-mcp` next to the
    /// executable in a SwiftPM build.
    static func serverURL(bundleURL: URL = Bundle.main.bundleURL,
                          executableURL: URL? = Bundle.main.executableURL) -> URL? {
        let candidate = bundleURL.pathExtension == "app"
            ? bundleURL.appendingPathComponent("Contents/Helpers/phone-use-mcp")
            : executableURL?.deletingLastPathComponent().appendingPathComponent("phone-use-mcp")
        guard let candidate, FileManager.default.isExecutableFile(atPath: candidate.path) else { return nil }
        return candidate
    }
}

/// Finds and runs client command-line tools the way the user's terminal would.
///
/// Apps start with a minimal PATH, while `claude` and `codex` usually live in places only the
/// login shell adds (and npm installs also need `node` on PATH), so PATH comes from that shell.
enum CommandLineTools {
    struct Result {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    private static let pathMarker = "__PHONE_USE_PATH__"

    /// Directories to search, the login shell's PATH first.
    static func searchPath() async -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let common = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin",
                      "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "/usr/bin", "/bin"]
        var directories = (await loginShellPath()) ?? []
        for directory in common where !directories.contains(directory) { directories.append(directory) }
        return directories
    }

    static func locate(_ name: String, in directories: [String]) -> URL? {
        directories.lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first {
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                    && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: $0.path)
            }
    }

    /// Runs `executable` from the home directory with `PATH` set to `path`.
    static func run(_ executable: URL, _ arguments: [String], path: [String],
                    timeout: TimeInterval = 30) async -> Result {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path.joined(separator: ":")
        return await run(executable, arguments, environment: environment, timeout: timeout)
    }

    static func parseLoginShellPath(_ output: String) -> [String]? {
        let parts = output.components(separatedBy: pathMarker)
        guard parts.count >= 3 else { return nil }
        let directories = parts[parts.count - 2].split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return directories.isEmpty ? nil : directories
    }

    private static func loginShellPath() async -> [String]? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        // Interactive too, because many people extend PATH in .zshrc rather than .zprofile.
        // Braces matter: the marker's underscores would otherwise extend the variable name.
        let script = "printf '%s' \"\(pathMarker)${PATH}\(pathMarker)\""
        let result = await run(URL(fileURLWithPath: shell), ["-ilc", script],
                               environment: ProcessInfo.processInfo.environment, timeout: 5)
        return parseLoginShellPath(result.output)
    }

    private static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                            timeout: TimeInterval) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: runBlocking(executable, arguments, environment: environment, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: URL, _ arguments: [String], environment: [String: String],
                                    timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: "\(error)")
        }
        // This process's copy of the write end would otherwise keep the pipe from reaching EOF.
        try? pipe.fileHandleForWriting.close()

        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let deadline = Date().addingTimeInterval(timeout)
        var exitedAt: Date?
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&request, 1, 100) > 0 {
                let count = read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break } // EOF
                output.append(buffer, count: count)
                continue
            }
            if process.isRunning {
                if Date() > deadline { process.terminate() }
            } else if let exitedAt {
                // A grandchild still holds the pipe open; stop waiting for it.
                if Date().timeIntervalSince(exitedAt) > 0.5 { break }
            } else {
                exitedAt = Date()
            }
        }
        // EOF can come before exit; a tool that closes its output and lingers still gets the timeout.
        if exited.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
            process.terminate()
            exited.wait()
        }
        try? pipe.fileHandleForReading.close()
        return Result(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self))
    }
}
