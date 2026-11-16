import AppKit
import PhoneUseKit
import PhoneUseMCP
import Foundation

// MCP server over stdio (newline-delimited JSON-RPC 2.0), as a bridge to the phone-use app.
// Tools run inside the app, which shares its device sessions with the preview. The bridge answers
// initialize and tools/list itself and launches the app in the background on the first tool call.
// stdout carries protocol messages only; diagnostics go to stderr.

/// Serializes writes so replies from the app and local replies never interleave.
final class StandardOutput: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ message: Data) {
        lock.withLock { FileHandle.standardOutput.write(message + Data([0x0A])) }
    }
}

enum AppLauncher {
    enum LaunchError: Error, CustomStringConvertible {
        case notFound
        case spawnFailed(Int32)

        var description: String {
            switch self {
            case .notFound: "phone-use.app could not be found. Install it or set DEVICEHUB_APP to its path."
            case .spawnFailed(let code): "Starting phone-use-app failed (\(String(cString: strerror(code))))."
            }
        }
    }

    /// Starts the app this bridge belongs to without a window: the enclosing .app bundle when
    /// installed, the `phone-use-app` next to this executable in a SwiftPM build, or the app
    /// LaunchServices knows by bundle identifier. `DEVICEHUB_APP` names either kind explicitly.
    static func launch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let target: URL
        if let override = environment["DEVICEHUB_APP"], !override.isEmpty {
            target = URL(fileURLWithPath: override)
        } else if let found = located() {
            target = found
        } else {
            throw LaunchError.notFound
        }
        let passed = environment.filter { $0.key.hasPrefix("DEVICEHUB_") && $0.key != "DEVICEHUB_APP" }
        if target.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            configuration.arguments = [PhoneUseAppBundle.backgroundArgument]
            configuration.environment = passed
            _ = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        } else {
            try spawnDetached(target, environment: environment)
        }
        FileHandle.standardError.write(Data("phone-use-mcp: started \(target.path) in the background\n".utf8))
    }

    private static func located() -> URL? {
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let directory = executable.deletingLastPathComponent()
        // phone-use.app/Contents/Helpers/phone-use-mcp
        let bundle = directory.deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" { return bundle }
        let sibling = directory.appendingPathComponent("phone-use-app")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: PhoneUseAppBundle.bundleIdentifier)
    }

    /// Runs a bare app executable in its own session, so it outlives this bridge and never
    /// writes to the client's stdout.
    private static func spawnDetached(_ executable: URL, environment: [String: String]) throws {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let arguments = [executable.path, PhoneUseAppBundle.backgroundArgument]
        let variables = environment.map { "\($0.key)=\($0.value)" }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = variables.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard status == 0 else { throw LaunchError.spawnFailed(status) }
    }
}

let standardOutput = StandardOutput()
let bridge = MCPBridge(launchApp: { try await AppLauncher.launch() },
                       output: { standardOutput.write($0) })

// Split on LF only: JSON may carry U+2028 and other characters `lines` would also break on.
var line = Data()
for try await byte in FileHandle.standardInput.bytes {
    if byte == 0x0A {
        await bridge.receive(line)
        line.removeAll(keepingCapacity: true)
    } else {
        line.append(byte)
    }
}
if !line.isEmpty { await bridge.receive(line) }
await bridge.finish()
