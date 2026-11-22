import AppKit
import AppUpdates
import PhoneUseKit
import PhoneUseMCP
import PhoneUseUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by a view, so MCP clients can use the daemon before any window opens.
    let model = DeviceListModel()
    let mcp = MCPHost()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare SwiftPM executable, so opt into a Dock icon and focus explicitly.
        NSApp.setActivationPolicy(.regular)
        if !MCPHost.launchedInBackground { NSApp.activate() }
        mcp.start(workspace: MCPWorkspaceAccess(
            selectedDevice: { [model] in await model.selection },
            select: { [model] device in await model.selectDevice(device) },
            connect: { [model] device in try await model.connectDevice(device) },
            unlock: { try await DeviceUnlockController.shared.unlock($0) },
            endPreview: { [model] device in await model.endPreview(for: device) },
            changeGeometry: { [model] device, change in try await model.changeGeometry(for: device, change: change) }
        )) { [model] in try await model.launcher.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let finish = MCPServer.finishRecordingsBeforeTermination() else { return .terminateNow }
        Task {
            await finish.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.record("process.stop")
        mcp.stop()
        model.stop()
    }

    /// SwiftUI does not reopen a `Window` scene that launched suppressed or was closed while MCP
    /// kept the app alive, so clicking the Dock icon or opening the app again does it here.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showMainWindow() }
        return true
    }

    /// Opens the main window through its Window menu item (`MainWindowCommands`).
    private func showMainWindow() {
        guard let menu = NSApp.windowsMenu,
              let index = menu.items.firstIndex(where: { $0.title == PhoneUseMacApp.mainWindowTitle }) else { return }
        menu.performActionForItem(at: index)
    }

    /// Closing the last window quits, unless an MCP client still uses the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        guard mcp.connectionCount == 0 else {
            mcp.windowsClosed()
            return false
        }
        return true
    }
}

@main
struct PhoneUseMacApp: App {
    static let mainWindowTitle = "PhoneUse"
    static let mainWindowID = "device-main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updater = AppUpdater()

    init() {
        PhoneUseConfiguration.current = .phoneUse
        Diagnostics.startup()
    }

    var body: some Scene {
        Window(Self.mainWindowTitle, id: Self.mainWindowID) {
            PhoneUseWindow()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.mcp.activity)
        }
        .defaultSize(width: 1280, height: 920)
        // Started by phone-use-mcp: serve without a window until the user opens one. Restoring
        // the window an earlier run left open would show it anyway.
        .defaultLaunchBehavior(MCPHost.launchedInBackground ? .suppressed : .automatic)
        .restorationBehavior(MCPHost.launchedInBackground ? .disabled : .automatic)
        .commands {
            MainWindowCommands()
            DiagnosticCommands()
            MCPSetupCommands()
            CommandGroup(after: .appInfo) {
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
        }

        Settings {
            TabView {
                MCPSettingsView()
                    .tabItem { Label("AI 助手", systemImage: "sparkles") }
            }
        }
    }
}

/// Lists the main window in the Window menu even while it is closed. SwiftUI leaves the item out
/// when the window launched suppressed, which would leave no way back to it.
struct MainWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .singleWindowList) {
            Button(PhoneUseMacApp.mainWindowTitle) { openWindow(id: PhoneUseMacApp.mainWindowID) }
        }
    }
}
