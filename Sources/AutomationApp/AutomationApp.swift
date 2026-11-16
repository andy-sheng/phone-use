import AppKit
import PhoneUseKit
import PhoneUseUI
import SwiftUI

extension PhoneUseConfiguration {
    /// automation keeps its own daemon, socket and device cache. automation-bridge falls back to
    /// the same identity when run without one.
    static let automation = PhoneUseConfiguration.application(identifier: "dev.devicehub.automation",
                                                              displayName: "automation")
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
        automation.stop()
        model.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct AutomationMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        PhoneUseConfiguration.current = .automation
    }

    var body: some Scene {
        Window("automation", id: "automation-main") {
            AutomationWindow(automation: appDelegate.automation)
                .environmentObject(appDelegate.model)
        }
        .defaultSize(width: 1280, height: 920)
    }
}
