import AppKit
import DeviceHubKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    var automation: AutomationModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare SwiftPM executable, so opt into a Dock icon and focus explicitly.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            automation?.stop()
            model?.stop()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DeviceHubApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var automation = AutomationModel()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        Window("phone-use", id: "device-main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(automation)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.automation = automation
                    updater.setTaskRunning(automation.isBusy)
                }
                .onChange(of: automation.isBusy) { _, running in updater.setTaskRunning(running) }
        }
        .defaultSize(width: 1280, height: 920)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates || automation.isBusy)
            }
        }
    }
}
