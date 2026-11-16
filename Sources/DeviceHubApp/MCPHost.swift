import AppKit
import DeviceHubKit
import Foundation
import os

/// Serves MCP tool calls from `phone-use-mcp` inside the app, so agents share the app's daemon
/// and device sessions with the preview.
///
/// The bridge launches the app with `--background` when no instance serves, and then no window
/// opens. Whenever no window is showing and no MCP client is connected, the app quits after a
/// grace period, taking its daemon with it.
@MainActor
final class MCPHost {
    static let launchedInBackground = CommandLine.arguments.contains(PhoneUseApp.backgroundArgument)
    /// Launched by LaunchServices the app has no stderr, so state goes to the unified log.
    private static let log = Logger(subsystem: "dev.devicehub.app", category: "mcp")

    private let idleGrace: Duration
    private var server: MCPSocketServer?
    private(set) var connectionCount = 0
    private var idleQuit: Task<Void, Never>?

    init(idleGrace: Duration = .seconds(60)) {
        self.idleGrace = idleGrace
    }

    /// Starts serving; `prepare` runs before each tool call to make sure the daemon is up.
    func start(prepare: @escaping @MainActor @Sendable () async throws -> Void) {
        let server = MCPSocketServer(
            handler: { line in await MCPServer.handle(line: line, prepare: prepare) },
            onConnectionCountChange: { [weak self] count in
                Task { @MainActor in self?.connectionCountChanged(count) }
            })
        self.server = server
        Task {
            do {
                try await server.start()
                Self.log.notice("Serving MCP on \(DeviceHubPaths.mcpSocket, privacy: .public)")
            } catch {
                self.server = nil
                Self.log.error("MCP unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        scheduleIdleQuit()
    }

    func stop() {
        idleQuit?.cancel()
        server?.stop()
        server = nil
    }

    /// Re-evaluates idling once the last window closed while clients stayed connected.
    func windowsClosed() {
        scheduleIdleQuit()
    }

    private func connectionCountChanged(_ count: Int) {
        connectionCount = count
        if count == 0 { scheduleIdleQuit() } else { idleQuit?.cancel() }
    }

    private func scheduleIdleQuit() {
        idleQuit?.cancel()
        guard connectionCount == 0, !Self.hasVisibleWindow else { return }
        idleQuit = Task { [idleGrace] in
            try? await Task.sleep(for: idleGrace)
            guard !Task.isCancelled, self.connectionCount == 0, !Self.hasVisibleWindow else { return }
            Self.log.notice("No window and no MCP client; quitting")
            NSApp.terminate(nil)
        }
    }

    /// A hidden app (⌘H) still counts: its windows come back when it is shown again.
    private static var hasVisibleWindow: Bool {
        NSApp.isHidden || NSApp.windows.contains { $0.isVisible || $0.isMiniaturized }
    }
}
