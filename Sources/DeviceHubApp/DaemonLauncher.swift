import DeviceHubKit
import Foundation

/// Runs the Python daemon as a child process for as long as the app lives.
///
/// The daemon watches its stdin and exits when the app does, so it never outlives us. The MCP
/// server and CLI only connect to it; they never start one.
@MainActor
final class DaemonLauncher {
    struct Runtime {
        let python: URL
        let daemonDirectory: URL
        let bundled: Bool
    }

    enum LaunchError: Error, CustomStringConvertible {
        case runtimeMissing
        case didNotStart

        var description: String {
            switch self {
            case .runtimeMissing: "The phone-use daemon runtime is missing. Run scripts/setup-dev.sh or reinstall phone-use."
            case .didNotStart: "The phone-use daemon did not start."
            }
        }
    }

    private var process: Process?
    private var stdin: Pipe?
    private var stopping = false
    private var recentExits: [Date] = []

    /// Starts the daemon unless one already answers on the socket, and waits until it does.
    func start() async throws {
        stopping = false
        if await DaemonClient.isReachable() { return }
        // The daemon we launched may still be starting or restarting; never run two side by side,
        // because the extra one would only exit with the app.
        if process?.isRunning != true {
            guard let runtime = Self.locateRuntime() else { throw LaunchError.runtimeMissing }
            try spawn(runtime)
        }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            if await DaemonClient.isReachable() { return }
            if process?.isRunning == false { break }
        }
        // Alive but unreachable: stop it so the next attempt starts a fresh one.
        if let process, process.isRunning { process.terminate() }
        throw LaunchError.didNotStart
    }

    func stop() {
        stopping = true
        try? stdin?.fileHandleForWriting.close()
        process = nil
        stdin = nil
    }

    private func spawn(_ runtime: Runtime) throws {
        let process = Process()
        process.executableURL = runtime.python
        process.arguments = ["-m", "devicehubd", "--socket", DeviceHubPaths.socket, "--watch-stdin"]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = runtime.daemonDirectory.path
        environment["PYTHONNOUSERSITE"] = "1"
        if runtime.bundled {
            // Writing bytecode into the signed bundle would invalidate its signature.
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            // The daemon resolves the bundled adb fallback and the pinned scrcpy server from here.
            if environment["DEVICEHUB_ANDROID_ASSETS"] == nil,
               let assets = Bundle.main.resourceURL?.appendingPathComponent("android") {
                environment["DEVICEHUB_ANDROID_ASSETS"] = assets.path
            }
        }
        process.environment = environment
        let pipe = Pipe()
        process.standardInput = pipe
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        process.terminationHandler = { [weak self] exited in
            let id = ObjectIdentifier(exited)
            Task { @MainActor in self?.daemonExited(id, runtime) }
        }
        try process.run()
        self.process = process
        stdin = pipe
    }

    private func daemonExited(_ exited: ObjectIdentifier, _ runtime: Runtime) {
        // Only the current daemon is restarted; a replaced one exiting is expected.
        guard !stopping, process.map(ObjectIdentifier.init) == exited else { return }
        let now = Date()
        recentExits = recentExits.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard recentExits.count <= 5 else {
            FileHandle.standardError.write(Data("devicehubd keeps exiting; not restarting it again\n".utf8))
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            // start() may already have launched a replacement meanwhile.
            guard !stopping, process?.isRunning != true else { return }
            try? spawn(runtime)
        }
    }

    static func locateRuntime() -> Runtime? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        if let python = environment["DEVICEHUB_PYTHON"], let directory = environment["DEVICEHUB_DAEMON_DIR"] {
            return Runtime(python: URL(fileURLWithPath: python), daemonDirectory: URL(fileURLWithPath: directory), bundled: false)
        }
        if let resources = Bundle.main.resourceURL {
            let python = resources.appendingPathComponent("python/bin/python3")
            let daemon = resources.appendingPathComponent("daemon")
            if fileManager.isExecutableFile(atPath: python.path) {
                return Runtime(python: python, daemonDirectory: daemon, bundled: true)
            }
        }
        // Development checkout: Sources/DeviceHubApp/DaemonLauncher.swift -> repository root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let python = root.appendingPathComponent(".venv-daemon/bin/python")
        if fileManager.isExecutableFile(atPath: python.path) {
            return Runtime(python: python, daemonDirectory: root.appendingPathComponent("Daemon"), bundled: false)
        }
        return nil
    }
}
