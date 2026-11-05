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

    var body: some Scene {
        Window("phone-use", id: "device-main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(automation)
                .onAppear {
                    appDelegate.model = model
                    appDelegate.automation = automation
                }
        }
        .defaultSize(width: 1280, height: 920)

    }
}
