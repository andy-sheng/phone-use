import AppKit
import AppUpdates
import PhoneUseKit
import PhoneUseUI
import SwiftUI

extension PhoneUseConfiguration {
    /// automation keeps its own daemon, socket and device cache. automation-bridge falls back to
    /// the same identity when run without one.
    static let automation = PhoneUseConfiguration.application(identifier: "cn.andysheng.automation",
                                                              displayName: "Automation")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = DeviceListModel()
    let automation = AutomationModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare SwiftPM executable, so opt into a Dock icon and focus explicitly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.record("process.stop")
        automation.stop()
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AutomationMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var updater = AppUpdater()

    init() {
        PhoneUseConfiguration.current = .automation
        Diagnostics.startup()
    }

    var body: some Scene {
        Window("Automation", id: "automation-main") {
            AutomationWindow(automation: appDelegate.automation)
                .environmentObject(appDelegate.model)
                .onReceive(appDelegate.automation.$isRunning, perform: updater.setTaskRunning)
        }
        .defaultSize(width: 1280, height: 920)
        .commands {
            DiagnosticCommands { appDelegate.automation.diagnosticRunDirectories }
            CommandGroup(after: .appInfo) {
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
