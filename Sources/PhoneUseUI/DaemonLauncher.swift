import PhoneUseKit
import Foundation

/// Runs the Python daemon as a child process for as long as the app lives.
///
/// The daemon watches its stdin and exits when the app does, so it never outlives us. It
/// starts with `PhoneUseConfiguration.current`, so each app keeps its own daemon, socket and state.
@MainActor
public final class DaemonLauncher {
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
            case .runtimeMissing:
                let name = PhoneUseConfiguration.current.displayName
                return "The \(name) daemon runtime is missing. Run scripts/setup-dev.sh or reinstall \(name)."
            case .didNotStart: return "The \(PhoneUseConfiguration.current.displayName) daemon did not start."
            }
        }
    }

    private var process: Process?
    private var stdin: Pipe?
    private var stopping = false
    private var recentExits: [Date] = []

    public init() {}

    /// Starts the daemon unless one already answers on the socket, and waits until it does.
    public func start() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        stopping = false
        if await DaemonClient.isReachable() {
            Diagnostics.record("daemon.ready")
            return
        }
        // The daemon we launched may still be starting or restarting; never run two side by side,
        // because the extra one would only exit with the app.
        if process?.isRunning != true {
            guard let runtime = Self.locateRuntime() else {
                Diagnostics.record("daemon.runtime.missing")
                throw LaunchError.runtimeMissing
            }
            try spawn(runtime)
        }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            if await DaemonClient.isReachable() {
                Diagnostics.record("daemon.ready", ["elapsed_ms": Diagnostics.elapsed(since: started)])
                return
            }
            if process?.isRunning == false { break }
        }
        // Alive but unreachable: stop it so the next attempt starts a fresh one.
        if let process, process.isRunning { process.terminate() }
        Diagnostics.record("daemon.start.unavailable", ["elapsed_ms": Diagnostics.elapsed(since: started), "timeout_ms": "15000"])
        throw LaunchError.didNotStart
    }

    public func stop() {
        Diagnostics.record("daemon.stop")
        stopping = true
        try? stdin?.fileHandleForWriting.close()
        process = nil
        stdin = nil
    }

    private func spawn(_ runtime: Runtime) throws {
        let process = Process()
        process.executableURL = runtime.python
        process.arguments = ["-m", "devicehubd", "--socket", PhoneUseConfiguration.current.socketPath, "--watch-stdin"]
        var environment = ProcessInfo.processInfo.environment
        environment.merge(PhoneUseConfiguration.current.environment) { _, identity in identity }
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
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { [output] handle in
            let data = handle.availableData
            guard !data.isEmpty else { output.fileHandleForReading.readabilityHandler = nil; return }
            Diagnostics.output(data)
        }
        process.terminationHandler = { [weak self] exited in
            // The read handler drains through EOF independently; do not block restart waiting
            // for a worker that inherited stderr, or race a second read against that handler.
            Diagnostics.record("daemon.exit", ["pid_child": String(exited.processIdentifier), "status": String(exited.terminationStatus)])
            let id = ObjectIdentifier(exited)
            Task { @MainActor in self?.daemonExited(id, runtime) }
        }
        Diagnostics.record("daemon.start", ["bundled": String(runtime.bundled)])
        do { try process.run() } catch {
            output.fileHandleForReading.readabilityHandler = nil
            Diagnostics.record("daemon.start.failed", ["error": String(describing: error)])
            throw error
        }
        self.process = process
        stdin = pipe
    }

    private func daemonExited(_ exited: ObjectIdentifier, _ runtime: Runtime) {
        // Only the current daemon is restarted; a replaced one exiting is expected.
        guard !stopping, process.map(ObjectIdentifier.init) == exited else { return }
        let now = Date()
        recentExits = recentExits.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard recentExits.count <= 5 else {
            Diagnostics.record("daemon.restart.exhausted")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            // start() may already have launched a replacement meanwhile.
            guard !stopping, process?.isRunning != true else { return }
            try? spawn(runtime)
        }
    }

    public static var pythonExecutable: URL? { locateRuntime()?.python }

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
        // Development checkout: Sources/PhoneUseUI/DaemonLauncher.swift -> repository root.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let python = root.appendingPathComponent(".venv-daemon/bin/python")
        if fileManager.isExecutableFile(atPath: python.path) {
            return Runtime(python: python, daemonDirectory: root.appendingPathComponent("Daemon"), bundled: false)
        }
        return nil
    }
}
