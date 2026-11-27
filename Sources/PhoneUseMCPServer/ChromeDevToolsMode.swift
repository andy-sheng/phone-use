import Darwin
import Foundation
import PhoneUseKit

enum ChromeRuntime {
    static let executable = Bundle.main.executableURL!.resolvingSymlinksInPath()
    static let resources = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    static let checkout = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let packaged = FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("python/bin/python3").path)
    static let directory = packaged ? resources.appendingPathComponent("chrome-mcp")
                                    : checkout.appendingPathComponent(".build/chrome-mcp/current")
}

/// Replace the stdio bridge so the upstream MCP server owns this client's stdin/stdout.
func startChromeDevTools(arguments: [String]) async throws -> Never {
    let fileManager = FileManager.default
    let resources = ChromeRuntime.resources
    let checkout = ChromeRuntime.checkout
    let bundled = resources.appendingPathComponent("phoneuse_chrome_mcp.py")
    let packaged = ChromeRuntime.packaged
    let python = packaged ? resources.appendingPathComponent("python/bin/python3")
                          : checkout.appendingPathComponent(".venv-daemon/bin/python")
    let script = packaged ? bundled : checkout.appendingPathComponent("Sources/PhoneUseApp/Resources/phoneuse_chrome_mcp.py")
    guard fileManager.isExecutableFile(atPath: python.path), fileManager.fileExists(atPath: script.path) else {
        throw CocoaError(.fileNoSuchFile)
    }
    if !arguments.contains("--help") && ProcessInfo.processInfo.environment["DEVICEHUB_SOCKET"] == nil {
        if !(await DaemonClient.isReachable()) {
            try await AppLauncher.launch()
            for _ in 0..<60 {
                if await DaemonClient.isReachable() { break }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    let args = [python.path, "-B", script.path, "--runtime", ChromeRuntime.directory.path, "--socket", PhoneUseConfiguration.current.socketPath] + arguments
    let argv = args.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    // A Swift concurrency worker may block termination signals. The replacement
    // process and its stdio child must receive MCP client termination normally.
    var signals = sigset_t()
    sigemptyset(&signals)
    sigaddset(&signals, SIGTERM)
    sigaddset(&signals, SIGINT)
    pthread_sigmask(SIG_UNBLOCK, &signals, nil)
    execv(python.path, argv)
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}
